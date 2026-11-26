<?php
/**
 * Reset Cipi GUI primary admin — invoked by lib/gui.sh (cipi gui reset-user).
 * Usage: php gui-reset-admin.php <payload.json> <laravel-root>
 */
$payload = json_decode(file_get_contents($argv[1] ?? ''), true);
$root = $argv[2] ?? '';

if (! is_array($payload) || $root === '' || ! is_file($root.'/artisan')) {
    fwrite(STDERR, "Invalid reset payload\n");
    exit(1);
}

require $root.'/vendor/autoload.php';
$app = require $root.'/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

$user = App\Models\User::query()->orderBy('id')->first();
if (! $user) {
    fwrite(STDERR, "No admin user found\n");
    exit(1);
}

$user->forceFill([
    'email' => $payload['email'] ?? $user->email,
    'name' => $payload['name'] ?? $user->name,
    // Plain password — Laravel User model uses the "hashed" cast (do not Hash::make here).
    'password' => $payload['password'],
    'two_factor_secret' => null,
    'two_factor_enabled' => false,
    'two_factor_confirmed_at' => null,
])->save();

// Passkeys (cipi/gui 4.8.0) are a second factor too: left in place, the
// password set here would still be followed by a passkey the person lost.
if (Schema::hasTable('cipi_passkeys')) {
    DB::table('cipi_passkeys')->where('user_id', $user->id)->delete();
}

if (Schema::hasTable('sessions') && Schema::hasColumn('sessions', 'user_id')) {
    DB::table('sessions')->where('user_id', $user->id)->delete();
}

fwrite(STDOUT, "OK: {$user->email}\n");
