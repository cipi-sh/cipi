<?php
/*
 * Cipi — Git push webhook receiver for apps without cipi/agent (Node apps).
 *
 * Installed at /usr/local/share/cipi/webhook.php. nginx sends only
 * POST /cipi/webhook here, through a PHP-FPM pool that runs as the app user
 * with open_basedir limited to the app's home, so this script can do exactly
 * one thing: drop ~/.deploy-trigger for the app's own crontab to pick up.
 * It never runs git, dep or a shell.
 *
 * Verification is the same as cipi/agent's:
 *   GitHub     X-Hub-Signature-256: sha256=HMAC(body, secret)
 *   Bitbucket  X-Hub-Signature:     sha256=HMAC(body, secret)
 *   GitLab     X-Gitlab-Token:      secret
 *   Azure      X-Gitlab-Token:      secret (Cipi registers the hook that way)
 * Only a push to the app's configured branch triggers a deploy. What the
 * payload says about the pusher is written into the trigger file and ends up
 * under "claimed" in the deploy audit ledger — never trusted as fact.
 */

declare(strict_types=1);

function cipi_reply(int $code, string $message): void
{
    http_response_code($code);
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    echo json_encode(['message' => $message]), "\n";
    exit;
}

function cipi_header(string $name): string
{
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    return isset($_SERVER[$key]) ? (string) $_SERVER[$key] : '';
}

function cipi_clean(?string $value, int $max = 128): string
{
    return substr((string) preg_replace('/[^A-Za-z0-9._@:\/+=, -]/', '', (string) $value), 0, $max);
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    cipi_reply(405, 'POST only');
}

$app = (string) ($_SERVER['CIPI_APP'] ?? '');
if (!preg_match('/^[a-z][a-z0-9]{2,31}$/', $app)) {
    cipi_reply(500, 'misconfigured');
}
$home = '/home/' . $app;
$config = json_decode((string) @file_get_contents($home . '/.cipi/webhook.json'), true);
$secret = is_array($config) ? (string) ($config['token'] ?? '') : '';
$branch = is_array($config) ? (string) ($config['branch'] ?? '') : '';
if ($secret === '' || $branch === '') {
    cipi_reply(503, 'webhook not configured');
}

$body = (string) file_get_contents('php://input', false, null, 0, 2 * 1024 * 1024);

// ── authenticate ─────────────────────────────────────────────
$provider = '';
$sig256 = cipi_header('X-Hub-Signature-256');
$sigBitbucket = cipi_header('X-Hub-Signature');
$token = cipi_header('X-Gitlab-Token');
if ($sig256 !== '') {
    $provider = 'github';
    $ok = hash_equals('sha256=' . hash_hmac('sha256', $body, $secret), $sig256);
} elseif ($sigBitbucket !== '' && str_starts_with($sigBitbucket, 'sha256=')) {
    $provider = 'bitbucket';
    $ok = hash_equals('sha256=' . hash_hmac('sha256', $body, $secret), $sigBitbucket);
} elseif ($token !== '') {
    $provider = cipi_header('X-Gitlab-Event') !== '' ? 'gitlab' : 'azure';
    $ok = hash_equals($secret, $token);
} else {
    $ok = false;
}
if (!$ok) {
    cipi_reply(403, 'invalid signature');
}

// ── event and branch ─────────────────────────────────────────
if ($provider === 'github' && cipi_header('X-GitHub-Event') === 'ping') {
    cipi_reply(200, 'pong');
}
$payload = json_decode($body, true);
if (!is_array($payload)) {
    cipi_reply(400, 'invalid payload');
}

$refs = [];
$actor = '';
$commit = '';
$delivery = '';
switch ($provider) {
    case 'github':
        if (cipi_header('X-GitHub-Event') !== 'push') {
            cipi_reply(202, 'ignored event');
        }
        $refs[] = (string) ($payload['ref'] ?? '');
        $actor = (string) ($payload['pusher']['name'] ?? $payload['sender']['login'] ?? '');
        $commit = (string) ($payload['after'] ?? '');
        $delivery = cipi_header('X-GitHub-Delivery');
        break;
    case 'gitlab':
        if (cipi_header('X-Gitlab-Event') !== 'Push Hook') {
            cipi_reply(202, 'ignored event');
        }
        $refs[] = (string) ($payload['ref'] ?? '');
        $actor = (string) ($payload['user_username'] ?? '');
        $commit = (string) ($payload['checkout_sha'] ?? '');
        $delivery = cipi_header('X-Gitlab-Event-UUID');
        break;
    case 'bitbucket':
        if (cipi_header('X-Event-Key') !== 'repo:push') {
            cipi_reply(202, 'ignored event');
        }
        foreach (($payload['push']['changes'] ?? []) as $change) {
            if (($change['new']['type'] ?? '') === 'branch') {
                $refs[] = 'refs/heads/' . (string) ($change['new']['name'] ?? '');
                $commit = (string) ($change['new']['target']['hash'] ?? $commit);
            }
        }
        $actor = (string) ($payload['actor']['nickname'] ?? $payload['actor']['display_name'] ?? '');
        $delivery = cipi_header('X-Request-UUID');
        break;
    case 'azure':
        if (($payload['eventType'] ?? '') !== 'git.push') {
            cipi_reply(202, 'ignored event');
        }
        foreach (($payload['resource']['refUpdates'] ?? []) as $update) {
            $refs[] = (string) ($update['name'] ?? '');
            $commit = (string) ($update['newObjectId'] ?? $commit);
        }
        $actor = (string) ($payload['resource']['pushedBy']['uniqueName'] ?? '');
        $delivery = (string) ($payload['id'] ?? '');
        break;
}

if (!in_array('refs/heads/' . $branch, $refs, true)) {
    cipi_reply(202, 'push to another branch — ignored');
}

// ── trigger ──────────────────────────────────────────────────
$meta = [
    'source' => $provider,
    'actor' => cipi_clean($actor),
    'ip' => cipi_clean((string) ($_SERVER['REMOTE_ADDR'] ?? ''), 64),
    'ref' => cipi_clean($branch . ($commit !== '' ? '@' . substr($commit, 0, 12) : '')),
    'request_id' => cipi_clean($delivery, 64),
];
$tmp = $home . '/.deploy-trigger.tmp-' . bin2hex(random_bytes(4));
if (@file_put_contents($tmp, json_encode($meta) . "\n") === false || !@rename($tmp, $home . '/.deploy-trigger')) {
    @unlink($tmp);
    cipi_reply(500, 'could not queue the deploy');
}
cipi_reply(202, 'deploy queued');
