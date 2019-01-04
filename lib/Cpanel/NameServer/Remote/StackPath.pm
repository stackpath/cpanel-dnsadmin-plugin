package Cpanel::NameServer::Remote::StackPath;

# An implementation of the cPanel dns clustering interface for StackPath's DNS
# backend
#
# See: https://github.com/stackpath/cpanel-dnsadmin-plugin for more information
# and licensing.

use strict;
use warnings;

use Cpanel::DnsUtils::RR         ();
use Cpanel::Encoder::URI         ();
use Cpanel::JSON                 ();
use Cpanel::JSON::XS             qw(encode_json);
use Cpanel::Logger               ();
use Cpanel::NameServer::Remote::StackPath::API;
use cPanel::PublicAPI            ();
use Cpanel::SocketIP             ();
use Cpanel::StringFunc::Match    ();
use Cpanel::ZoneFile             ();
use Cpanel::ZoneFile::Versioning ();
use HTTP::Date                   ();
use List::Util                   qw(min);
use List::MoreUtils              qw(any natatime none uniq);
use Time::Local                  qw(timegm);

use parent 'Cpanel::NameServer::Remote';

our $VERSION = '0.1.0';

# A cache of remote StackPath zones
#
# Zones and their resource records are stored in the format retrieved from the
# StackPath API.
my $local_cache = [];

# The number of items to retrieve from a StackPath API call
my $ITEMS_PER_REQUEST = 50;

# Zone resource record types supported by StackPath
my @SUPPORTED_RECORD_TYPES = ('A', 'AAAA', 'CNAME', 'MX', 'NS', 'SRV', 'TXT');

# Zone record types that need periods appended to their values when updated at
# StackPath
#
# This should be a subset of @SUPPORTED_RECORD_TYPES.
my @RECORDS_NEEDING_TRAILING_PERIODS = ('CNAME', 'MX', 'NS');

# A map of resource record types to the name of the field in a parsed cPanel
# zone file object that holds that record's data.
my $RECORD_DATA_FIELDS = {
    'A'     => 'address',
    'AAAA'  => 'address',
    'CNAME' => 'cname',
    'MX'    => 'exchange',
    'NS'    => 'nsdname',
    'SOA'   => 'rname',
    'SRV'   => 'target',
    'TXT'   => 'txtdata',
};

# StackPath's limit on bulk resource record operations
my $BULK_RESOURCE_RECORD_LIMIT = 1000;

# Build a new StackPath DNS module
sub new {
    my ($class, %args) = @_;
    my $debug = $args{'debug'} || 0;
    my $self = {
        'name'            => $args{'host'},
        'update_type'     => $args{'update_type'},
        'queue_callback'  => $args{'queue_callback'},
        'output_callback' => $args{'output_callback'},
        'stack_id'        => $args{'stack_id'},
        'debug'           => $debug,
        'http_client'     => Cpanel::NameServer::Remote::StackPath::API->new(
            'client_id'     => $args{'client_id'},
            'client_secret' => $args{'client_secret'},
            'timeout'       => $args{'remote_timeout'},
            'debug'         => $debug,
        ),
    };

    bless $self, $class;
    $local_cache = $self->_cache_zones();

    return $self;
}

# Adds a zone to the configuration database
sub addzoneconf {
    my ($self, $request_id, $input, $raw_input) = @_;
    chomp($input->{'zone'});

    # Add the zone to StackPath
    my $request_body = {'domain' => $input->{'zone'}};
    my $res = $self->{'http_client'}->request(
        'POST',
        sp_url(sprintf('/dns/v1/stacks/%s/zones', $self->{'stack_id'})),
        {'content' => encode_json($request_body)}
    );

    if (!$res->{'success'}) {
        return _fail(
            sprintf('Unable to save zone "%s": %s: %s', $input->{'zone'}, $res->{'status'}, $res->{'content'})
        );
    }

    # Add the zone to the local cache
    my $zone = $res->{'decoded_content'}->{'zone'};
    $zone->{'records'} = [];
    push @{$local_cache}, $zone;

    $self->output(sprintf("Added zone \"%s\" to %s\n", $input->{'zone'}, $self->{'name'}));
    return _success();
}

# Retrieve a complete dump of all of the zone files on the system
sub getallzones {
    my ($self, $request_id, $input, $raw_input) = @_;

    foreach my $zone (@{$local_cache}) {
        $self->output(sprintf(
            'cpdnszone-%s=%s&',
            Cpanel::Encoder::URI::uri_encode_str($zone->{'domain'}),
            Cpanel::Encoder::URI::uri_encode_str(_build_zone_file($zone))
        ));
    }
}

# Retrieve a list of the IP addresses that the system's nameserver records use
sub getips {
    my ($self, $request_id, $input, $raw_input) = @_;
    my @ips;

    foreach my $name_server (@{$self->_get_name_servers()}) {
        push @ips, Cpanel::SocketIP::_resolveIpAddress($name_server);
    }

    $self->output(join("\n", @ips) . "\n");
    return _success();
}

# List the nodes with which the current node is peered
#
# Note: The system uses this method to build the graph in WHM's DNS Cluster
# interface (WHM >> Home >> Clusters >> DNS Cluster).
sub getpath {
    my ($self, $request_id, $input, $raw_input) = @_;

    $self->output(join("\n", @{$self->_get_name_servers()}) . "\n");
    return _success();
}

# Retrieve the contents of a single zone file
sub getzone {
    my ($self, $request_id, $input, $raw_input) = @_;
    chomp($input->{'zone'});

    my @zones = _find_zone($input->{'zone'});
    my $size = scalar @zones;

    if ($size > 1) {
        return _fail(sprintf('more than one match found for zone "%s"', $input->{'zone'}));
    }

    if ($size == 0) {
        return _fail(sprintf('zone "%s" not found', $input->{'zone'}));
    }

    $self->output(_build_zone_file($zones[0]));
    return _success();
}

# List all of the available zones on the system
sub getzonelist {
    my ($self, $request_id, $input, $raw_input) = @_;
    my @zones = map { $_->{'domain'} } @{$local_cache};

    $self->output(join("\n", @zones) . "\n");
    return _success();
}

# Retrieve the contents of multiple zone files
sub getzones {
    my ($self, $request_id, $input, $raw_input) = @_;
    chomp($input->{'zone'});

    if (defined $input->{'zones'}) {
        chomp($input->{'zones'});
    }

    my @zones;
    my @search_for = split(/\,/, $input->{'zones'} || $input->{'zone'});

    # Look for zones in the cache
    foreach my $zone_name (@search_for) {
        chomp $zone_name;

        my @found_zones = _find_zone($zone_name);

        # Only render the zone if it's found in the cache
        if ((scalar @found_zones) == 1) {
            push @zones, $found_zones[0];
        }
    }

    # Render zones to BIND-compatible zone files
    foreach my $zone (@zones) {
        $self->output(sprintf(
            'cpdnszone-%s=%s&',
            Cpanel::Encoder::URI::uri_encode_str($zone->{'domain'}),
            Cpanel::Encoder::URI::uri_encode_str(_build_zone_file($zone))
        ));
    }

    return _success();
}

# Add a zone to the system and saves its contents
sub quickzoneadd {
    my ($self, $request_id, $input, $raw_input) = @_;

    return $self->savezone(sprintf('%s_1', $request_id), $input, $raw_input);
}

# Remove a single zone from the system
sub removezone {
    my ($self, $request_id, $input, $raw_input) = @_;
    chomp($input->{'zone'});

    # Make sure the zone exists
    my @zones = _find_zone($input->{'zone'});
    my $size = scalar @zones;

    if ($size > 1) {
        return _fail(sprintf('more than one match found for zone "%s"', $input->{'zone'}));
    }

    if ($size == 0) {
        return _fail(sprintf('zone "%s" not found', $input->{'zone'}));
    }

    # Remove the zone from the stack
    my $res = $self->{'http_client'}->request(
        'DELETE',
        sp_url(sprintf('/dns/v1/stacks/%s/zones/%s', $self->{'stack_id'}, $zones[0]->{'id'}))
    );

    if (!$res->{'success'}) {
        return _fail(
            sprintf('Unable to remove zone "%s": %s: %s', $input->{'zone'}, $res->{'status'}, $res->{'content'})
        );
    }

    # Remove the zone from the local cache
    my @new_cache = grep { $_->{'id'} ne $zones[0]->{'id'} } @{$local_cache};
    $local_cache = \@new_cache;

    $self->output(sprintf("%s => deleted from %s\n", $input->{'zone'}, $self->{'name'}));
    return _success();
}

# Remove multiple zones from the system
sub removezones {
    my ($self, $request_id, $input, $raw_input) = @_;
    chomp($input->{'zone'});

    if (defined $input->{'zones'}) {
        chomp($input->{'zones'});
    }

    my @zones;
    my @search_for = split(/\,/, $input->{'zones'} || $input->{'zone'});

    # Look for zones in the cache
    foreach my $zone_name (@search_for) {
        chomp $zone_name;

        my @found_zones = _find_zone($zone_name);

        if ((scalar @found_zones) == 1) {
            push @zones, $found_zones[0];
        }
    }

    # Remove each zone and fail out on the first error
    my $count = 0;
    foreach my $zone (@zones) {
        my ($code, $message) = $self->removezone(sprintf('%s_%s', $request_id, $count), {'zone' => $zone->{'domain'}}, {});

        if ($code != $Cpanel::NameServer::Constants::SUCCESS) {
            return _fail($message);
        }

        $count++;
    }

    return _success();
}

# Save new records to an existing zone file
#
# This method does not add the zone file to the configuration database (for
# example, the named.conf file on BIND servers).
sub savezone {
    my ($self, $request_id, $input, $raw_input) = @_;
    chomp($input->{'zone'});

    # Check if the zone exists
    my @zones = _find_zone($input->{'zone'});
    my $size = scalar @zones;
    my $zone_exists = $size == 1;

    if ($size > 1) {
        return _fail(sprintf('more than one match found for zone "%s"', $input->{'zone'}));
    }

    # Parse the zone file
    my $local_zone = eval {
        Cpanel::ZoneFile->new('domain' => $input->{'zone'}, 'text' => $input->{'zonedata'});
    };

    if (!$local_zone || $local_zone->{'error'}) {
        my $message = sprintf(
            "%s: Unable to save the zone %s on the remote server [%s] (Could not parse zonefile%s)",
            __PACKAGE__,
            $input->{'zone'},
            $self->{'name'},
            $local_zone ? sprintf(' - %s', $local_zone->{'error'}) : ''
        );

        return _fail($message, $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED);
    }

    # Add the zone if need be before setting zone records
    if (!$zone_exists) {
        my ($code, $message) = $self->addzoneconf($request_id, {'zone' => $input->{'zone'}}, {});

        if ($code != $Cpanel::NameServer::Constants::SUCCESS) {
            return _fail($message, $code)
        }

        @zones = _find_zone($input->{'zone'});
    }

    my $remote_zone = $zones[0];

    # Look for records in the zone file that already exist at StackPath. Leave
    # those records alone and don't sync them with StackPath. Delete the other
    # remote records then bulk-create the remaining records from the zonefile
    # object.
    #
    # The zonefile object doesn't contain StackPath record ids. Match existing
    # records by their type, name, data, and TTL.
    my @stackpath_records_to_delete = ();
    my @new_records = ();

    # Look for records to delete
    foreach my $remote_record (@{$remote_zone->{'records'}}) {
        if (none { _resource_record_matches($_, $remote_record, $input->{'zone'}) } @{$local_zone->{'dnszone'}}) {
            push @stackpath_records_to_delete, $remote_record;
        }
    }

    # Look for records to add
    foreach my $local_record (@{$local_zone->{'dnszone'}}) {
        # Skip resource records that aren't supported at StackPath
        if (!(any { $local_record->{'type'} eq $_ } @SUPPORTED_RECORD_TYPES)) {
            next;
        }

        # Avoid creating duplicate NS records for StackPath's name servers
        if ($local_record->{'type'} eq 'NS'
            && any { $_ eq $local_record->{$RECORD_DATA_FIELDS->{'NS'}} } @{$remote_zone->{'nameservers'}}
        ) {
            next;
        }

        # If the record already exists at StackPath then it doesn't need to be created
        my $record_matches = 0;
        foreach my $remote_record (@{$remote_zone->{'records'}}) {
            if (_resource_record_matches($local_record, $remote_record, $input->{'zone'})) {
                $record_matches = 1;
                last;
            }
        }

        if (!$record_matches) {
            push @new_records, $local_record;
        }
    }

    # Convert zonefile resource records to StackPath resource records
    @new_records = map { _to_stackpath_resource_record($_, $input->{'zone'}) } @new_records;

    # Delete changed records at StackPath
    if ((scalar @stackpath_records_to_delete) > 0) {
        my $iterator = natatime($BULK_RESOURCE_RECORD_LIMIT, @stackpath_records_to_delete);

        while (my @chunk = $iterator->()) {
            # StackPath takes a list of record IDs when bulk deleting
            @chunk = map { $_->{'id'} } @chunk;

            my $request_body = {'zoneRecordIds' => \@chunk};
            my $res = $self->{'http_client'}->request(
                'POST',
                sp_url(
                    sprintf(
                        '/dns/v1/stacks/%s/zones/%s/bulk/records/delete',
                        $self->{'stack_id'},
                        $remote_zone->{'id'}
                    )
                ),
                {'content' => encode_json($request_body)}
            );

            if (!$res->{'success'}) {
                return _fail(
                    sprintf('Unable to save zone "%s": %s: %s', $input->{'zone'}, $res->{'status'}, $res->{'content'})
                );
            }
        }
    }

    # Upload new and changed records to StackPath
    if ((scalar @new_records) > 0) {
        my $iterator = natatime($BULK_RESOURCE_RECORD_LIMIT, @new_records);

        while (my @chunk = $iterator->()) {
            my $request_body = {'records' => \@chunk};
            my $res = $self->{'http_client'}->request(
                'POST',
                sp_url(sprintf('/dns/v1/stacks/%s/zones/%s/bulk/records', $self->{'stack_id'}, $remote_zone->{'id'})),
                {'content' => encode_json($request_body)}
            );

            if (!$res->{'success'}) {
                return _fail(
                    sprintf('Unable to save zone "%s": %s: %s', $input->{'zone'}, $res->{'status'}, $res->{'content'})
                );
            }
        }
    }

    # Update the local cache with the new records
    my $i = 0;
    foreach my $zone (@{$local_cache}) {
        # Look for the right zone in the cache
        if ($zone->{'id'} ne $remote_zone->{'id'}) {
            $i++;
            next;
        }

        ${$local_cache}[$i]->{'records'} = [];
        my $has_next_page = 1;
        my $cursor = -1;

        while ($has_next_page) {
            my $res = $self->{'http_client'}->request(
                'GET',
                sp_url(
                    sprintf('/dns/v1/stacks/%s/zones/%s/records', $self->{'stack_id'}, $zone->{'id'}),
                    {
                        'page_request.first' => $ITEMS_PER_REQUEST,
                        'page_request.after' => $cursor,
                    }
                )
            );

            if (!$res->{'success'}) {
                return _fail('Error querying the StackPath API: %s: %s', $res->{'status'}, $res->{'content'});
            }

            push @{${$local_cache}[$i]->{'records'}}, @{$res->{'decoded_content'}->{'records'}};

            $has_next_page = $res->{'decoded_content'}->{'pageInfo'}->{'hasNextPage'};
            $cursor = $res->{'decoded_content'}->{'pageInfo'}->{'endCursor'};
        }

        last;
    }

    $self->output(sprintf("Saved zone \"%s\" to %s\n", $input->{'zone'}, $self->{'name'}));
    return _success();
}

# Add multiple zones to a remote system and to the configuration database (the
# named.conf file on BIND servers).
sub synczones {
    my ($self, $request_id, $input, $raw_input) = @_;

    # Remove the unique id value from input to save memory.
    $raw_input =~ s/^dnsuniqid=[^\&]+\&//;
    $raw_input =~ s/\&dnsuniqid=[^\&]+//g;

    # Build a list of zone names and contents
    my %zones = map { (split(/=/, $_, 2))[0, 1] } split(/\&/, $raw_input);
    delete @zones{grep(!/^cpdnszone-/, keys %zones)};

    # Save each zone in the input
    my $i = 0;
    foreach my $zone_name (keys %zones) {
        my $zone = $zones{$zone_name};
        $zone_name =~ s/^cpdnszone-//g;

        my ($code, $message) = $self->savezone(
            sprintf('%s_%s', $request_id, ++$i),
            {
                'zone' => Cpanel::Encoder::URI::uri_decode_str($zone_name),
                'zonedata' => Cpanel::Encoder::URI::uri_decode_str($zone),
            }
        );

        if ($code != $Cpanel::NameServer::Constants::SUCCESS) {
            return _fail($message, $code)
        }
    }

    return _success();
}

# Retrieve the module's version number
sub version {
    my ($self, $request_id, $input, $raw_input) = @_;
    return $VERSION;
}

# Determine if a zone exists
sub zoneexists {
    my ($self, $request_id, $input, $raw_input) = @_;
    chomp($input->{'zone'});

    my @found_zones = _find_zone($input->{'zone'});
    my $size = scalar @found_zones;

    if ($size > 1) {
        return _fail(sprintf('more than one match found for zone "%s"', $input->{'zone'}));
    }

    $self->output($size == 0 ? '0' : '1');
    return _success();
}

# Remove unnecessary DNS zones from the system
sub cleandns {
    my ($self, $request_id, $input, $raw_input) = @_;

    $self->output(sprintf("No cleanup needed on %s\n", $self->{'name'}));
    return _success();
}

# Force BIND to reload completely
sub reloadbind {
    my ($self, $request_id, $input, $raw_input) = @_;

    $self->output(sprintf("No reload needed on %s\n", $self->{'name'}));
    return _success();
}

# Force BIND to reload specific zones
sub reloadzones {
    my ($self, $request_id, $input, $raw_input) = @_;

    $self->output(sprintf("No reload needed on %s\n", $self->{'name'}));
    return _success();
}

# Force BIND to reload the configuration file
sub reconfigbind {
    my ($self, $request_id, $input, $raw_input) = @_;

    $self->output(sprintf("No reconfig needed on %s\n", $self->{'name'}));
    return _success();
}

# Send debug messages to the log file
sub _debug {
    my ($self, $message, $data) = @_;

    if (!$self->{'debug'}) {
        return $self;
    }

    return $self;
}

# A helper for success responses
sub _success {
    my ($message) = @_;

    if (!$message) {
        $message = 'OK';
    }

    return ($Cpanel::NameServer::Constants::SUCCESS, $message);
}

# A helper for failure responses
sub _fail {
    my ($message, $code) = @_;

    if (!$message) {
        $message = 'Unknown error';
    }

    if (!$code) {
        $code = $Cpanel::NameServer::Constants::ERROR_GENERIC;
    }

    return ($code, $message);
}

# Retrieve all zones and zone resource records from StackPath
#
# Zones are stored in the raw format as retrieved from StackPath but contain an
# additional {'records'} property which contains an arrayref of all of the
# zone's resource records.
sub _cache_zones {
    my ($self) = @_;
    my $has_next_page = 1;
    my $cursor = -1;
    my @zones;

    # Retrieve all zones on the stack
    while ($has_next_page) {
        my $res = $self->{'http_client'}->request(
            'GET',
            sp_url(
                sprintf('/dns/v1/stacks/%s/zones', $self->{'stack_id'}),
                {
                    'page_request.first' => $ITEMS_PER_REQUEST,
                    'page_request.after' => $cursor,
                }
            )
        );

        if (!$res->{'success'}) {
            die sprintf('Error querying the StackPath API: %s: %s', $res->{'status'}, $res->{'content'});
        }

        push @zones, @{$res->{'decoded_content'}->{'zones'}};

        $has_next_page = $res->{'decoded_content'}->{'pageInfo'}->{'hasNextPage'};
        $cursor = $res->{'decoded_content'}->{'pageInfo'}->{'endCursor'};
    }

    # Add resource records to each zone
    foreach my $zone (@zones) {
        $zone->{'records'} = [];
        $has_next_page = 1;
        $cursor = -1;

        while ($has_next_page) {
            my $res = $self->{'http_client'}->request(
                'GET',
                sp_url(
                    sprintf('/dns/v1/stacks/%s/zones/%s/records', $self->{'stack_id'}, $zone->{'id'}),
                    {
                        'page_request.first' => $ITEMS_PER_REQUEST,
                        'page_request.after' => $cursor,
                    }
                )
            );

            if (!$res->{'success'}) {
                die sprintf('Error querying the StackPath API: %s: %s', $res->{'status'}, $res->{'content'});
            }

            push @{$zone->{'records'}}, @{$res->{'decoded_content'}->{'records'}};

            $has_next_page = $res->{'decoded_content'}->{'pageInfo'}->{'hasNextPage'};
            $cursor = $res->{'decoded_content'}->{'pageInfo'}->{'endCursor'};
        }
    }

    return \@zones;
}

# Retrieve all nameservers serving zones on a stack
sub _get_name_servers {
    my ($self) = @_;
    my @name_servers;

    # Pull the name servers serving every zone in the cache.
    map { push(@name_servers, @{$_->{'nameservers'}}) } @{$local_cache};
    @name_servers = uniq @name_servers;

    return \@name_servers;
}

# Filter the local cache for zones with a matching domain name
sub _find_zone {
    my ($zone_name) = @_;

    return grep { $_->{'domain'} eq $zone_name } @{$local_cache};
}

# Determine if a cPanel zonefile resource record is the same as a StackPath
# resource record
#
# Compare basic basic and calculated record properties. If any of them do not
# match then the cPanel and StackPath records do not match.
sub _resource_record_matches {
    my ($cpanel, $stackpath, $zone_name) = @_;

    if ($cpanel->{'ttl'} != $stackpath->{'ttl'}) {
        return 0;
    }

    if (uc($cpanel->{'type'}) ne uc($stackpath->{'type'})) {
        return 0;
    }

    if (_to_stackpath_resource_record_name($cpanel->{'name'}, $zone_name) ne $stackpath->{'name'}) {
        return 0;
    }

    return _to_stackpath_resource_record_data($cpanel) eq $stackpath->{'data'};
}

# Convert a cPanel zonefile resource record into a StackPath resource record
sub _to_stackpath_resource_record {
    my ($record, $zone_name) = @_;

    return {
        'name'   => _to_stackpath_resource_record_name($record->{'name'}, $zone_name),
        'data'   => _to_stackpath_resource_record_data($record),
        'type'   => uc($record->{'type'}),
        'ttl'    => $record->{'ttl'},
        'weight' => $record->{'weight'},
        'labels' => {},
    };
}

# Convert a cPanel zonefile resource record name into its StackPath equivalent
#
# cPanel zonefile objects have fully qualified resource record names. Strip the
# trailing zone name off the end of the resource record's name so the StackPath
# record name matches what users see in the WHM GUI.
sub _to_stackpath_resource_record_name {
    my ($record_name, $zone_name) = @_;

    return $record_name =~ s/\.\Q$zone_name\E\.$//r,
}

# Convert a cPanel zonefile resource record into a StackPath resource record
# data field
sub _to_stackpath_resource_record_data {
    my ($record) = @_;
    my $type = uc($record->{'type'});
    my $data = $record->{$RECORD_DATA_FIELDS->{$record->{'type'}}};


    # Handle more complex data formats
    if ($type eq 'MX') {
        $data = _to_stackpath_mx_data($record);
    }

    if ($type eq 'SRV') {
        $data = _to_stackpath_srv_data($record);
    }

    if ($type eq 'TXT') {
        $data = Cpanel::DnsUtils::RR::encode_and_split_dns_txt_record_value($data);
    }

    # Add a trailing period if needed
    if (grep { $type eq $_ } @RECORDS_NEEDING_TRAILING_PERIODS) {
        $data .= '.';
    }

    return $data;
}

# Build a StackPath MX record data value
#
# StackPath stores MX record data in the format "<priority> <data>".
sub _to_stackpath_mx_data {
    my ($record) = @_;

    return sprintf('%s %s', $record->{'preference'}, $record->{$RECORD_DATA_FIELDS->{'MX'}});
}

# Build a StackPath SRV record data value
#
# StackPath stores SRV record data in the format
# "<priority> <weight> <port> <data>".
sub _to_stackpath_srv_data {
    my ($record) = @_;

    return sprintf(
        '%s %s %s %s',
        $record->{'priority'},
        $record->{'weight'},
        $record->{'port'},
        $record->{$RECORD_DATA_FIELDS->{'SRV'}}
    );
}

# Build a BIND zone file string from a zone and its resource records
sub _build_zone_file {
    my ($zone) = @_;
    my $zone_file = "";

    # Write the file's header with some metadata and $ORIGIN.
    $zone_file .= sprintf("; Domain:             %s\n", $zone->{'domain'});
    $zone_file .= sprintf("; Version:            %s\n", $zone->{'version'});
    $zone_file .= sprintf("; Created:            %s\n", $zone->{'created'});
    $zone_file .= sprintf("; Updated:            %s\n", $zone->{'updated'});
    $zone_file .= sprintf("; StackPath ID:       %s\n", $zone->{'id'});
    $zone_file .= sprintf("; StackPath Stack ID: %s\n\n", $zone->{'stackId'});
    $zone_file .= sprintf("\$ORIGIN %s.\n\n", $zone->{'domain'});

    # Write the SOA record
    #
    # Values are hardcoded to match how they're deployed at StackPath.
    $zone_file .= sprintf(
        "\@ 3600 IN SOA %s. dns.stackpathdns.net. %s 86400 7200 3600000 3600\n\n",
        $zone->{'nameservers'}[0],
        _iso8601_to_unix_time($zone->{'updated'})
    );

    # Write NS records
    #
    # NS record TTL is hardcoded to match how it's deployed at StackPath.
    foreach my $nameserver (@{$zone->{'nameservers'}}) {
        $zone_file .= sprintf("\@ 86400 IN NS %s.\n", $nameserver);
    }

    $zone_file .= "\n";

    # Write out resource records
    foreach my $record (@{$zone->{'records'}}) {
        # Include metadata before the resource record
        $zone_file .= sprintf("; StackPath ID: %s\n", $record->{'id'});
        $zone_file .= sprintf("; Created:      %s\n", $record->{'created'});

        if (defined $record->{'updated'}) {
            $zone_file .= sprintf("; Updated:      %s\n", $record->{'updated'});
        }

        $zone_file .= sprintf(
            "%s %d %s %s %s\n\n",
            $record->{'name'},
            $record->{'ttl'},
            $record->{'class'},
            $record->{'type'},
            $record->{'data'}
        );
    }

    chomp $zone_file;

    return $zone_file;
}

# Convert an ISO8601 timestamp to a UNIX timestamp
#
# Adapted from https://www.perlmonks.org/?node_id=1078246.
sub _iso8601_to_unix_time {
    my ($iso) = @_;
    my ($date, $time) = split(/T/ => $iso);
    my ($year, $month, $day) = split(/-/ => $date);
    my ($hour, $minute, $second) = split(/:/ => $time);

    $year -= 1900;
    $month -= 1;

    return sprintf("%.0f", timegm($second, $minute, $hour, $day, $month, $year));
}

1;
