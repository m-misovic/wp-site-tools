<?php
/**
 * Plugin Name: Staging Guard
 * Description: Keeps copies of the site from acting like production: no e-mail, no production-only plugins, hidden from search engines.
 * Version: 1.0.0
 * Author: {{AUTHOR}}
 *
 * A copy of the site (staging, a local clone, a host's one-click copy) carries production's
 * database, so it would send real e-mail, report to production's accounts and get indexed.
 * The guard acts everywhere except on the production hosts below, so a copy is covered
 * however it was made. It is a must-use plugin because only those load before the plugins
 * it has to stop. Deploys ship it to production too, where it does nothing.
 * {{SITE_NOTES: optional lines on plugins kept on deliberately, e.g. a consent plugin the site's own code reads}}
 */

namespace StagingGuard;

defined( 'ABSPATH' ) || exit;

// Hosts where the site is production. Every other host is a copy. The names are split on
// purpose: Hostinger's staging tool replaces the production domain with the staging one in
// every file it copies, which would turn this list into the staging host and switch the
// guard off on a new staging site until the first deploy.
const PRODUCTION_HOSTS = [ '{{DOMAIN_LABEL}}' . '.{{TLD}}', 'www.{{DOMAIN_LABEL}}' . '.{{TLD}}' ];

// Plugin folders that must not run on a copy, because they report to production's accounts
// or carry production's connection to them. One line each, with the reason.
const PRODUCTION_ONLY_PLUGINS = [
	{{PRODUCTION_ONLY_PLUGINS: e.g. 'google-site-kit', // Google Analytics and the Ads tag.}}
];

if ( in_array( strtolower( (string) parse_url( (string) get_option( 'home' ), PHP_URL_HOST ) ), PRODUCTION_HOSTS, true ) ) {
	return;
}

// Mail stays testable where it provably ends in Local's Mailpit. Anywhere else, including
// WP-CLI run with the system PHP on a developer's machine, report every message as sent and
// send none, as Disable Emails does.
if ( ! mail_goes_to_mailpit() ) {
	add_filter( 'pre_wp_mail', '__return_true', PHP_INT_MAX );
}

add_filter( 'option_active_plugins', __NAMESPACE__ . '\without_production_only_plugins', PHP_INT_MAX );
add_filter( 'pre_option_blog_public', '__return_zero', PHP_INT_MAX );
add_action( 'admin_notices', __NAMESPACE__ . '\notice' );
add_action( 'admin_bar_menu', __NAMESPACE__ . '\admin_bar_node', 100 );

/**
 * Leave production-only plugins out of the active list, without changing the database.
 *
 * @param mixed $plugins Active plugin files, such as "google-site-kit/google-site-kit.php".
 *
 * @return mixed
 */
function without_production_only_plugins( $plugins ) {
	if ( ! is_array( $plugins ) ) {
		return $plugins;
	}

	$blocked = blocked_plugins();

	return array_values(
		array_filter(
			$plugins,
			fn( $plugin ) => ! in_array( dirname( (string) $plugin ), $blocked, true )
		)
	);
}

/**
 * Whether PHP hands mail to Local's catcher rather than a real mail server.
 *
 * Only Local's own PHP sends to Mailpit (or MailHog on older Local versions); the system
 * PHP that WP-CLI often runs with uses the machine's sendmail, which can deliver for real.
 *
 * @return bool
 */
function mail_goes_to_mailpit(): bool {
	return 'local' === wp_get_environment_type()
		&& 1 === preg_match( '/mail(pit|hog)/i', (string) ini_get( 'sendmail_path' ) );
}

/**
 * Production-only plugins this copy loads anyway.
 *
 * Only on Local, and only when its own wp-config.php (never in Git) names them, for example
 * define( 'STAGING_GUARD_ALLOW', [ 'woocommerce-payments' ] ); to read production's data.
 * Such a plugin runs on production's connection, so nothing that moves or ends that
 * connection (a "Transfer", "Disconnect" or "Reconnect" button) may be clicked on the copy.
 *
 * @return string[]
 */
function allowed_plugins(): array {
	if ( 'local' !== wp_get_environment_type() || ! defined( 'STAGING_GUARD_ALLOW' ) ) {
		return [];
	}

	return array_values( array_intersect( PRODUCTION_ONLY_PLUGINS, (array) constant( 'STAGING_GUARD_ALLOW' ) ) );
}

/**
 * Production-only plugins this copy does not load.
 *
 * @return string[]
 */
function blocked_plugins(): array {
	return array_values( array_diff( PRODUCTION_ONLY_PLUGINS, allowed_plugins() ) );
}

/**
 * One line describing what the guard does on this copy.
 *
 * @return string
 */
function summary(): string {
	$parts = [ mail_goes_to_mailpit() ? 'e-mail goes to Local\'s Mailpit' : 'e-mail is blocked' ];

	if ( blocked_plugins() ) {
		$parts[] = 'not loaded: ' . implode( ', ', blocked_plugins() );
	}
	$parts[] = 'hidden from search engines';

	return 'Staging guard (' . wp_parse_url( home_url(), PHP_URL_HOST ) . '): ' . implode( '; ', $parts ) . '.';
}

/**
 * Show on every admin screen that this is a guarded copy, and loudly which production connections it lets through.
 *
 * @return void
 */
function notice(): void {
	printf( '<div class="notice notice-warning"><p>%s</p></div>', esc_html( summary() ) );

	if ( allowed_plugins() ) {
		printf(
			'<div class="notice notice-error"><p><strong>%s</strong></p></div>',
			esc_html( 'Production connection active through STAGING_GUARD_ALLOW: ' . implode( ', ', allowed_plugins() ) . '. Never click Transfer, Disconnect or Reconnect here; remove the constant when done.' )
		);
	}
}

/**
 * Mark the toolbar as well, so a copy is never mistaken for production.
 *
 * @param \WP_Admin_Bar $admin_bar The toolbar.
 *
 * @return void
 */
function admin_bar_node( \WP_Admin_Bar $admin_bar ): void {
	$admin_bar->add_node(
		[
			'id'    => 'staging-guard',
			'title' => 'STAGING COPY',
			'meta'  => [ 'title' => summary() ],
		]
	);
}
