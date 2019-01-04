package Cpanel::NameServer::Setup::Remote::StackPath;

# Set up the StackPath DNS backend for use in a cPanel DNS cluster
#
# See: https://github.com/stackpath/cpanel-dnsadmin-plugin for more information
# and licensing.

use strict;
use warnings;

use Cpanel::FileUtils::Copy ();
use Cpanel::JSON::XS        ();
use Cpanel::NameServer::Remote::StackPath::API;
use Whostmgr::ACLS          ();

our $VERSION = '0.1.0';

Whostmgr::ACLS::init_acls();

sub setup {
    my $self = shift;
    my %OPTS = @_;

    # Validate permissions
    if (!Whostmgr::ACLS::checkacl('clustering')) {
        return 0, 'User does not have the clustering ACL enabled.';
    }

    # Validate parameter existence
    if (!defined $OPTS{'client_id'}) {
        return 0, 'No OAuth2 client id given';
    }

    if (!defined $OPTS{'client_secret'}) {
        return 0, 'No OAuth2 client secret given';
    }

    if (!defined $OPTS{'stack_id'}) {
        return 0, 'No stack id given';
    }

    my $client_id     = $OPTS{'client_id'};
    my $client_secret = $OPTS{'client_secret'};
    my $stack_id      = $OPTS{'stack_id'};
    my $debug         = $OPTS{'debug'} ? 1 : 0;

    # Validate parameter values
    $client_id =~ tr/\r\n\f\0//d;
    $client_secret =~ tr/\r\n\f\0//d;
    $stack_id =~ tr/\r\n\f\0//d;

    if (!$client_id) {
        return 0, 'Invalid OAuth2 client id given';
    }

    if (!$client_secret) {
        return 0, 'Invalid OAuth2 client secret given';
    }

    if (!$stack_id) {
        return 0, 'Invalid stack id given';
    }

    # Validate the config at StackPath
    my ($valid, $validation_message) = _validate_config($client_id, $client_secret, $stack_id);

    if (!$valid) {
        return 0, sprintf(
            'Unable to validate your configuration: %s. Please verify your StackPath OAuth2 credentials and stack id',
            $validation_message
        );
    }

    # Save the configuration file
    my ($saved, $save_message) = _save_config($ENV{'REMOTE_USER'}, $client_id, $client_secret, $stack_id, $debug);

    if (!$saved) {
        return 0, $save_message;
    }

    return 1, 'The trust relationship with StackPath has been established.', '', 'stackpath';
}

sub get_config {
    my %config = (
        'options' => [
            {
                'name'        => 'client_id',
                'type'        => 'text',
                'locale_text' => 'StackPath OAuth2 client id',
            },
            {
                'name'        => 'client_secret',
                'type'        => 'text',
                'locale_text' => 'StackPath OAuth2 client secret',
            },
            {
                'name'        => 'stack_id',
                'type'        => 'text',
                'locale_text' => 'The stack to place all DNS zones on',
            },
            {
                'name'        => 'debug',
                'locale_text' => 'Debug mode',
                'type'        => 'binary',
                'default'     => 0,
            },
        ],
        'name' => 'StackPath',

        # Company IDs that this module should show up for
        'companyids' => [150, 477, 425, 7],
    );

    return wantarray ? %config : \%config;
}

# Validate a config with the StackPath API
#
# Build a StackPath API client with the config and make sure the requesting
# user has access to the configured stack ID.
sub _validate_config {
    my ($client_id, $client_secret, $stack_id) = @_;
    my $http_client = eval {
        Cpanel::NameServer::Remote::StackPath::API->new(
            client_id     => $client_id,
            client_secret => $client_secret,
        );
    };

    if ($@ ne '') {
        return 0, $@;
    }

    # Try to retrieve the stack_id and make sure a success response comes back.
    # If a success response is returned then the stack_id exists and the
    # requesting user has access to it.
    my $res = $http_client->request('GET', sp_url(sprintf('/stack/v1/stacks/%s', $stack_id)));

    if (!$res->{'success'}) {
        return 0, 'error validating stack_id';
    }

    # Double check that the user wants to use an active stack
    if (!$res->{'decoded_content'}->{'status'} || $res->{'decoded_content'}->{'status'} ne 'ACTIVE') {
        return 0, 'invalid stack_id';
    }

    return 1, 'configuration is valid';
}

# Save the DNS trust configuration file
sub _save_config {
    my ($safe_remote_user, $client_id, $client_secret, $stack_id, $debug) = @_;
    $safe_remote_user =~ s/\///g;

    # Make sure the config directory exists
    my $CLUSTER_ROOT     = '/var/cpanel/cluster';
    my $USER_ROOT        = $CLUSTER_ROOT . '/' . $safe_remote_user;
    my $CONFIG_ROOT      = $USER_ROOT . '/config';
    my $USER_CONFIG_FILE = $CONFIG_ROOT . '/stackpath';
    my $ROOT_CONFIG_FILE = $CLUSTER_ROOT . '/root/config/stackpath';

    foreach my $path ($CLUSTER_ROOT, $USER_ROOT, $CONFIG_ROOT) {
        if (!-e $path) {
            mkdir $path, 700;
        }
    }

    # Write the config file
    if (open my $fh, '>', $USER_CONFIG_FILE) {
        chmod 0600, $USER_CONFIG_FILE or warn "Failed to secure permissions on cluster configuration: $!";
        print {$fh} sprintf(
            "#version 2.0\nclient_id=%s\nclient_secret=%s\nstack_id=%s\nmodule=StackPath\ndebug=%s\n",
            $client_id,
            $client_secret,
            $stack_id,
            $debug
        );
        close $fh;
    } else {
        warn "Could not write DNS trust configuration file: $!";
        return 0, "The trust relationship could not be established, please examine /usr/local/cpanel/logs/error_log for more information.";
    }

    if (!-e $ROOT_CONFIG_FILE && Whostmgr::ACLS::hasroot()) {
        Cpanel::FileUtils::Copy::safecopy($USER_CONFIG_FILE, $ROOT_CONFIG_FILE);
    }

    return 1, 'saved DNS trust configuration';
}

1;
