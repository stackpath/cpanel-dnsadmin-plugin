package Cpanel::NameServer::Remote::StackPath::API;

# A wrapper around HTTP::Tiny for use with the StackPath API
#
# See: https://github.com/stackpath/cpanel-dnsadmin-plugin for more information
# and licensing.

use strict;
use warnings;

use Cpanel::JSON::XS;
use HTTP::Tiny;
use URL::Encode qw(url_encode_utf8);

our @ISA = qw(Exporter);
our @EXPORT = qw(sp_url);

our $VERSION = '0.1.0';
my $API_SCHEME = 'https';
my $API_HOST = 'gateway.stackpath.com';

# Build an HTTP::Tiny-like client that's authenticated to the StackPath API.
sub new {
    my ($class, %args) = @_;

    # Validate input
    if (!defined $args{'client_id'}) {
        die("client_id not defined\n");
    }

    if (!defined $args{'client_secret'}) {
        die("client_secret not defined\n");
    }

    if (!defined $args{'timeout'}) {
        $args{'timeout'} = 60;
    }

    if (!defined $args{'debug'}) {
        $args{'debug'} = 0;
    }

    # Get an OAuth2 bearer token to use in subsequent API calls
    my $access_token = eval {
        _authenticate($args{'client_id'}, $args{'client_secret'})
    };

    if ($@ ne '') {
        die("Unable to authenticate to the StackPath API: $@\n");
    }

    # Build the object
    my $self = {
        'debug' => $args{'debug'} ? 1 : 0,
    };

    # Add an authenticated HTTP client to the object
    $self->{'http_client'} = HTTP::Tiny->new(
        'agent'           => sprintf('%s/%s', __PACKAGE__, $VERSION),
        'verify_SSL'      => 1,
        'keep_alive'      => 1,
        'timeout'         => $args{'timeout'},
        'default_headers' => {
            'Accept'        => 'application/json',
            'content-type'  => 'application/json',
            'Authorization' => sprintf('Bearer %s', $access_token),
        },
    );

    bless $self, $class;
    return $self;
}

# Authenticate to the StackPath API by retrieving an OAuth2 bearer token
sub _authenticate {
    my ($client_id, $client_secret) = @_;
    my $token_body = {
        'client_id'     => $client_id,
        'client_secret' => $client_secret,
        'grant_type'    => 'client_credentials',
    };

    # Build an interim HTTP::Tiny client to authenticate the client id and
    # secret.
    my $res = HTTP::Tiny->new(
        'agent'           => sprintf('%s/%s', __PACKAGE__, $VERSION),
        'verify_SSL'      => 1,
        'keep_alive'      => 1,
        'default_headers' => {'Accept' => 'application/json', 'content-type' => 'application/json'},
    )->request('POST', sp_url('/identity/v1/oauth2/token'), {'content' => encode_json($token_body)});

    my $decoded = eval {
        decode_json($res->{'content'});
    };

    if ($@ ne '') {
        die("unable to decode OAuth2 token response\n");
    }

    # Send authentication errors back to the caller
    if (!$res->{'success'}) {
        die($decoded->{'error'} . "\n");
    }

    # Make sure the response contains a bearer token
    if ($decoded->{'token_type'} ne 'bearer') {
        die("no bearer token_type in OAuth2 token response\n");
    }

    if (!$decoded->{'access_token'}) {
        die("no access_token in OAuth2 token response\n");
    }

    return $decoded->{'access_token'};
}

# Make a request of the StackPath API
#
# Pass request parameters to the underlying HTTP::Tiny instance. Calls to
# request() are of the same format and response as HTTP::Tiny::request() with
# an extra decoded_content item in the response containing the JSON decoded
# response body.
sub request {
    my ($self, $method, $url, $args) = @_;

    if (!$args) {
        $args = {};
    }

    $self->_debug('Making a StackPath API call');
    $self->_debug(sprintf('Method: %s', $method));
    $self->_debug(sprintf('URL: %s', $url));
    $self->_debug('Arguments', $args);

    my $response = $self->{'http_client'}->request($method, $url, $args);

    $self->_debug('Response', $response);

    # Don't try to decode non-JSON responses.
    if ($response->{'headers'}->{'content-type'} ne 'application/json') {
        $response->{'decoded_content'} = $response->{'content'};
        return $response;
    }

    # JSON decode the response body to make life a little easier for the
    # caller. The StackPath API should always return JSON, so error out if the
    # response wasn't able to decode.
    $response->{'decoded_content'} = eval {
        decode_json($response->{'content'});
    };

    if ($@ ne '') {
        $self->_debug('Unable to JSON decode StackPath API response');
        die("unable to decode StackPath API response\n");
    }

    return $response;
}

# Print a debug message to the API object's error file
sub _debug {
    my ($self, $message, $data) = @_;

    # Only debug when configured to
    if (!$self->{debug}) {
        return $self;
    }

    warn "debug: " . $message . "\n";

    if ($data) {
        use Data::Dumper;
        warn Dumper($data) . "\n";
    }

    return $self;
}

# Quick-build a StackPath API URL
sub sp_url {
    my ($path, $query) = @_;
    my $query_string = '';

    if ($query && ref $query eq 'HASH') {
        my @query_string_parts = ();

        while (my ($key, $value) = each %{$query}) {
            push @query_string_parts, sprintf('%s=%s', url_encode_utf8($key), url_encode_utf8($value));
        }

        $query_string = sprintf('?%s', join('&', @query_string_parts));
    }

    return $API_SCHEME . '://' . $API_HOST . $path . $query_string;
}

1;
