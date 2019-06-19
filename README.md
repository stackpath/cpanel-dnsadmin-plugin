# A cPanel dnsadmin Plugin for StackPath DNS

Synchronize your [cPanel](https://cpanel.net/) systems' DNS zones with 
[StackPath](https://stackpath.com/)'s global DNS infrastructure with this 
plugin for cPanel's DNS clustering system. After installed and configured the 
plugin immediately propagates all of your DNS changes to StackPath with no 
effort required on your part.

* [Requirements](#requirements)
* [Installation](#installation)
  * [Add API credentials](#add-api-credentials)
  * [Find your stack id](#find-your-stack-id)
  * [Install the plugin](#install-the-plugin)
  * [Configure the plugin](#configure-the-plugin)
* [Usage](#usage)
* [Uninstallation](#uninstallation)
* [Troubleshooting](#troubleshooting)
* [Known Issues](#known-issues)
* [Development](#development)
  * [Development Links](#development-links)
* [See Also](#see-also)

<a name="requirements"></a>
## Requirements

* An active StackPath account with API credentials.
* A StackPath stack to place DNS zones on.
* A working cPanel installation. This plugin was developed in cPanel 11.76 but 
  will likely work in many earlier versions.
* Installing the plugin requires a valid WHM login and root shell access to the 
  cPanel installation.

<a name="installation"></a>
## Installation
<a name="add-api-credentials"></a>
### Add API credentials

1. Log into the [StackPath portal](https://control.stackpath.com/).
2. Click on your name in the top right corner of the page and click "API 
   Management".
3. We recommend using API credentials dedicated to cPanel DNS integration. Click 
   the "Generate Credentials" button, enter a name for your API credentials like 
   "cPanel DNS integration" then click the "Save" button.
4. Record the API client id and secret. For security reasons StackPath will only 
   show you the client secret once. Please save the secret before closing API 
   Client Secret modal window.

<a name="find-your-stack-id"></a>
### Find your stack id

StackPath accounts have a single stack by default, but it may be useful to 
create a stack dedicated to DNS zones synced by cPanel. Organize your stacks 
based on your apps' needs and how you use your StackPath account.

Stack ids are a UUID version 4 formatted string, eg. `5e70e17b-6007-408a-a271-2424d2e61291`. 
They appear near the end of the URL of the stack overview page in the StackPath 
portal. Navigate to the stack you'd like to store your DNS zones on and note its 
id in the URL. 

<a name="install-the-plugin"></a>
### Install the plugin

1. Copy this project to a temporary directory on your cPanel server.
2. Execute the `install.sh` script as root. This copies the plugin and 
   support modules in place.

<a name="configure-the-plugin"></a>
### Configure the plugin

1. Log into WHM.
2. Look for the "Clusters" section in the menu on the left side of the page and 
   click the "DNS Cluster" link.
3. Scroll to the "Add a new server to the cluster " box in the "Servers in your 
   DNS cluster" section of the page.
4. Select "StackPath" in the dropdown box then click "Configure".
5. Enter your StackPath account's API client id, client secret, and the UUID of 
   the stack you would like your zones to appear on in the text fields provided 
   then click "Submit".

cPanel will validate your input your input with StackPath and save StackPath in 
your DNS cluster. You can change this information on this screen later.

<a name="usage"></a>
## Usage

After installation the plugin automatically sends DNS change to StackPath's DNS 
backend with no interaction required by the user.

<a name="uninstallation"></a>
## Uninstallation

1. Copy this project to a temporary directory on your cPanel server.
2. Execute the `uninstall.sh` script as root. This removes all files and 
directories installed by the `install.sh` script. 

After the plugin is uninstalled then cPanel will no longer synchronize DNS zone 
changes with StackPath.

<a name="troubleshooting"></a>
## Troubleshooting

cPanel prints errors to the page if there were issues saving your zones to your 
StackPath stack. More information about these errors can usually be found in the 
cPanel error log at `/usr/local/cpanel/logs/error_log` or the dnsadmin log at 
`/usr/local/cpanel/logs/dnsadmin_log`.

If all else fails open a [bug report](https://github.com/stackpath/cpanel-dnsadmin-plugin/issues) 
and one of our staff will help out. 

<a name="known-issues"></a>
## Known Issues

* StackPath does not support editing SOA records and zone TTL. Any changes made 
  to SOA records and overall TTLs in cPanel will not propagate to StackPath.
* StackPath supports the A, AAAA, CNAME, MX, NS, SRV, and TXT resource record 
  types. Other record types saved in cPanel do not propagate to StackPath.
* cPanel dnsadmin is a one-way synchronization. Zone changes in cPanel propagate 
  immediately to StackPath when they're saved, but changes to zones made through 
  StackPath's portal or API are not sent back to your cPanel installation. 

<a name="development"></a>
## Development

This plugin has three modules:

* **`Cpanel::NameServer::Remote::Setup::StackPath`**  
  Located at `/usr/local/cpanel/Cpanel/NameServer/Remote/Setup/StackPath.pm`.  
  Defines and saves the configuration necessary for StackPath DNS integration. 
  This module is executed on the DNS Cluster configuration page in WHM.

* **`Cpanel::NameServer::Remote::StackPath`**  
  Located at `/usr/local/cpanel/Cpanel/NameServer/Remote/StackPath.pm`.  
  An implementation of the cPanel dnsadmin command module interface for use with 
  StackPath DNS. 

* **`Cpanel::NameServer::Remote::StackPath::API`**  
  Located at `/usr/local/cpanel/Cpanel/NameServer/Remote/StackPath/API.pm`.  
  A wrapper around [`HTTP::Tiny`](https://metacpan.org/pod/HTTP::Tiny) for 
  StackPath API connectivity. 

Modules contain references to internal cPanel modules and variables, so 
development requires a working cPanel installation. To prevent service 
interruptions we highly recommend developing on a test cPanel installation with 
test StackPath API credentials and stacks.

Edit these modules on the cPanel server and test changes by editing a DNS zone 
in WHM or synchronizing zones between cPanel and StackPath. Watch your zones in 
WHM and the StackPath portal to make sure changes applied correctly. Editing 
modules does not require restarting any cPanel daemons. 

Debug code in these modules by `warn`ing statements to the dnsadmin log at 
`/usr/local/cpanel/logs/dnsadmin_log`. cPanel's internal Perl environment 
includes the [`Data::Dumper`](https://metacpan.org/pod/Data::Dumper) module to 
make it easier to visualize complex data structures. For example, to write a 
StackPath API call result to the dnsadmin log file from the 
`Cpanel::NameServer::Remote::Setup::StackPath` module:

```perl5
my $res = $self->{'http_client'}->request(
    'GET',
    sp_url(sprintf('/dns/v1/stacks/%s/zones', $self->{'stack_id'})),
);

use Data::Dumper;
warn Dumper($res);
```

Watch the cPanel error log at `/usr/local/cpanel/logs/error_log` and the 
dnsadmin log at `/usr/local/cpanel/logs/dnsadmin_log` for more information 
during your development.

We welcome contributions and pull requests to this plugin. See our 
[contributing guide](https://github.com/stackpath/cpanel-dnsadmin-plugin/blob/master/.github/contributing.md) 
for more information.

<a name="development-links"></a>
### Development Links

* [Guide to Custom dnsadmin Plugins - cPanel Developer Documentation](https://documentation.cpanel.net/display/DD/Guide+to+Custom+dnsadmin+Plugins)
* [StackPath DNS API reference](https://developer.stackpath.com/en/api/dns/)

<a name="see-also"></a>
## See Also

* [DNS - StackPath Help Center](https://support.stackpath.com/hc/en-us/sections/360000205523-DNS)
* [Guide to DNS Cluster Configurations - cPanel Knowledge Base](https://documentation.cpanel.net/display/CKB/Guide+to+DNS+Cluster+Configurations)
