package Netdot::Model::Device::CiscoIOS;

use base 'Netdot::Model::Device';
use warnings;
use strict;
use Net::Appliance::Session;

my $logger = Netdot->log->get_logger('Netdot::Model::Device');

# Some regular expressions
my $IPV4 = Netdot->get_ipv4_regex();
my $IPV6 = Netdot->get_ipv6_regex();
my $CISCO_MAC = '\w{4}\.\w{4}\.\w{4}';

=head1 NAME

Netdot::Model::Device::CiscoIOS - Cisco IOS Class

=head1 SYNOPSIS

 Overrides certain methods from the Device class. More Specifically, methods in 
 this class try to obtain forwarding tables and ARP/ND caches via CLI
 instead of via SNMP.

=head1 CLASS METHODS
=cut

=head1 INSTANCE METHODS
=cut

=head2 get_arp - Fetch ARP tables

  Arguments:
    session - SNMP session (optional)
  Returns:
    Hashref
  Examples:
    my $cache = $self->get_arp(%args)
=cut
sub get_arp {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_arp');
    my $host = $self->fqdn;

    unless ( $self->collect_arp ){
	$logger->debug(sub{"Device::CiscoIOS::_get_arp: $host excluded from ARP collection. Skipping"});
	return;
    }
    if ( $self->is_in_downtime ){
	$logger->debug(sub{"Device::CiscoIOS::_get_arp: $host in downtime. Skipping"});
	return;
    }

    # This will hold both ARP and v6 ND caches
    my %cache;

    ### v4 ARP
    my $start = time;
    my $arp_count = 0;
    my $arp_cache = $self->_get_arp_from_cli(host=>$host) ||
	$self->_get_arp_from_snmp(session=>$argv{session});
    foreach ( keys %$arp_cache ){
	$cache{'4'}{$_} = $arp_cache->{$_};
	$arp_count+= scalar(keys %{$arp_cache->{$_}})
    }
    my $end = time;
    $logger->info(sub{ sprintf("$host: ARP cache fetched. %s entries in %s", 
			       $arp_count, $self->sec2dhms($end-$start) ) });
    
    ### v6 ND
    $start = time;
    my $nd_count = 0;
    my $nd_cache  = $self->_get_v6_nd_from_cli(host=>$host) ||
    	$self->_get_v6_nd_from_snmp($argv{session});
    # Here we have to go one level deeper in order to
    # avoid losing the previous entries
    foreach ( keys %$nd_cache ){
    	foreach my $ip ( keys %{$nd_cache->{$_}} ){
    	    $cache{'6'}{$_}{$ip} = $nd_cache->{$_}->{$ip};
    	    $nd_count++;
    	}
    }
    $end = time;
    $logger->info(sub{ sprintf("$host: IPv6 ND cache fetched. %s entries in %s", 
    				$nd_count, $self->sec2dhms($end-$start) ) });

    return \%cache;


}

############################################################################
=head2 get_fwt - Fetch forwarding tables

  Arguments:
    session - SNMP session (optional)    
  Returns:
    Hashref
  Examples:
    my $fwt = $self->get_fwt(%args)
=cut
sub get_fwt {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_fwt');
    my $host = $self->fqdn;
    my $fwt = {};

    unless ( $self->collect_fwt ){
	$logger->debug(sub{"Device::CiscoIOS::get_fwt: $host excluded from FWT collection. Skipping"});
	return;
    }
    if ( $self->is_in_downtime ){
	$logger->debug(sub{"Device::CiscoIOS::get_fwt: $host in downtime. Skipping"});
	return;
    }

    my $start     = time;
    my $fwt_count = 0;
    
    # Try CLI, and then SNMP 
    $fwt = $self->_get_fwt_from_cli(host=>$host) ||
	$self->_get_fwt_from_snmp(session=>$argv{session});

    map { $fwt_count+= scalar(keys %{$fwt->{$_}}) } keys %$fwt;
    my $end = time;
    $logger->debug(sub{ sprintf("$host: FWT fetched. %s entries in %s", 
				$fwt_count, $self->sec2dhms($end-$start) ) });
   return $fwt;

}


############################################################################
#_get_arp_from_cli - Fetch ARP tables via CLI
#    
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_arp_from_cli(host=>'foo');
#
sub _get_arp_from_cli {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_arp_from_cli');

    my $host = $argv{host};
    my $args = $self->_get_credentials(host=>$host);
    return unless ref($args) eq 'HASH';

    my @output = $self->_cli_cmd(%$args, host=>$host, cmd=>'show ip arp');

    my %cache;
    shift @output; # Ignore header line
    # Lines look like this:
    # Internet  10.82.250.129           -   0000.0c9f.f002  ARPA   GigabitEthernet0/3.2335
    foreach my $line ( @output ) {
	my ($iname, $ip, $mac, $intid);
	chomp($line);
	if ( $line =~ /^Internet\s+($IPV4)\s+[-\d]+\s+($CISCO_MAC)\s+ARPA\s+(\S+)/o ) {
	    $ip    = $1;
	    $mac   = $2;
	    $iname = $3;
	}else{
	    $logger->debug(sub{"Device::CiscoIOS::_get_arp_from_cli: line did not match criteria: $line" });
	    next;
	}
	unless ( $ip && $mac && $iname ){
	    $logger->debug(sub{"Device::CiscoIOS::_get_arp_from_cli: Missing information: $line" });
	    next;
	}
	$cache{$iname}{$ip} = $mac;
    }
    return $self->_validate_arp(\%cache, 4);
}

############################################################################
#_get_v6_nd_from_cli - Fetch ARP tables via CLI
#    
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_v6_nd_from_cli(host=>'foo');
#
sub _get_v6_nd_from_cli {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_v6_nd_from_cli');

    my $host = $argv{host};
    my $args = $self->_get_credentials(host=>$host);
    return unless ref($args) eq 'HASH';

    my @output = $self->_cli_cmd(%$args, host=>$host, cmd=>'show ipv6 neighbors');
    shift @output; # Ignore header line
    my %cache;
    foreach my $line ( @output ) {
	my ($ip, $mac, $iname);
	chomp($line);
	# Lines look like this:
	# FE80::219:E200:3B7:1920                     0 0019.e2b7.1920  REACH Gi0/2.3
	if ( $line =~ /^($IPV6)\s+\d+\s+($CISCO_MAC)\s+\S+\s+(\S+)/o ) {
	    $ip    = $1;
	    $mac   = $2;
	    $iname = $3;
	}else{
	    $logger->debug(sub{"Device::CiscoIOS::_get_v6_nd_from_cli: line did not match criteria: $line" });
	    next;
	}
	unless ( $iname && $ip && $mac ){
	    $logger->debug(sub{"Device::CiscoIOS::_get_v6_nd_from_cli: Missing information: $line"});
	    next;
	}
	$cache{$iname}{$ip} = $mac;
    }
    return $self->_validate_arp(\%cache, 6);
}


############################################################################
# _validate_arp - Validate contents of ARP and v6 ND structures
#    
#   Arguments:
#       hashref of hashrefs containing ifIndex, IP address and Mac
#       IP version
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_v6_nd_from_snmp();
#
#
sub _validate_arp {
    my($self, $cache, $version) = @_;
    $self->isa_object_method('_validate_arp');

    $self->throw_fatal("Device::_validate_arp: Missing required arguments")
	unless ($cache && $version);

    my $host = $self->fqdn();

    # MAP interface names to IDs
    # Get all interface IPs for subnet validation
    my %int_names;
    my %devsubnets;
    foreach my $int ( $self->interfaces ){
	my $name = $self->_reduce_iname($int->name);
	$int_names{$name} = $int->id;
	if ( Netdot->config->get('IGNORE_IPS_FROM_ARP_NOT_WITHIN_SUBNET') ){
	    foreach my $ip ( $int->ips ){
		next unless ($ip->version == $version);
		push @{$devsubnets{$int->id}}, $ip->parent->_netaddr 
		    if $ip->parent;
	    }
	}
    }
    my %valid;
    foreach my $key ( keys %{$cache} ){
	my $iname = $self->_reduce_iname($key);
	my $intid = $int_names{$iname};
	unless ( $intid ) {
	    $logger->warn("Device::CiscoIOS::_validate_arp: $host: Could not match $iname to any interface name");
	    next;
	}
	foreach my $ip ( keys %{$cache->{$key}} ){
	    if ( $version == 6 && Ipblock->is_link_local($ip) ){
		next;
	    }
	    my $mac = $cache->{$key}->{$ip};
	    my $validmac = PhysAddr->validate($mac); 
	    unless ( $validmac ){
		$logger->debug(sub{"Device::_validate_arp: $host: Invalid MAC: $mac" });
		next;
	    }
	    $mac = $validmac;
	    if ( Netdot->config->get('IGNORE_IPS_FROM_ARP_NOT_WITHIN_SUBNET') ){
		foreach my $nsub ( @{$devsubnets{$intid}} ){
		    my $nip = NetAddr::IP->new($ip) or
			$self->throw_fatal(sprintf("Device::CiscoIOS::_validate_arp: Cannot create NetAddr::IP ".
						   "object from %s", $ip));
		    if ( $nip->within($nsub) ){
			$valid{$intid}{$ip} = $mac;
			$logger->debug(sub{"Device::CiscoIOS::_validate_arp: $host: valid: $iname -> $ip -> $mac" });
			last;
		    }else{
			$logger->debug(sub{"Device::CiscoIOS::_validate_arp: $host: $ip not within $nsub" });
		    }
		}
	    }else{
		$valid{$intid}{$ip} = $mac;
		$logger->debug(sub{"Device::CiscoIOS::_validate_arp: $host: valid: $iname -> $ip -> $mac" });
	    }
	}
    }
    return \%valid;
}


############################################################################
#_get_fwt_from_cli - Fetch forwarding tables via CLI
#
#    
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#    
#   Examples:
#     $self->_get_fwt_from_cli();
#
#
sub _get_fwt_from_cli {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_fwt_from_cli');

    my $host = $argv{host};
    my $args = $self->_get_credentials(host=>$host);
    return unless ref($args) eq 'HASH';

    my @output = $self->_cli_cmd(%$args, host=>$host, cmd=>'show mac-address-table dynamic');

    # MAP interface names to IDs
    my %int_names;
    foreach my $int ( $self->interfaces ){
	my $name = $int->name;
	# Shorten names to match output
	# i.e GigabitEthernet1/2 -> Gi1/2
	$name =~ s/^([a-z]{2}).+?([\d\/]+)$/$1$2/i;
	$int_names{$name} = $int->id;
    }
    

    my ($iname, $mac, $intid);
    my %fwt;
    
    # Output look like this:
    #  vlan   mac address     type    learn     age              ports
    # ------+----------------+--------+-----+----------+--------------------------
    #   128  0024.b20e.fe0f   dynamic  Yes        255   Gi9/22

    foreach my $line ( @output ) {
	chomp($line);
	if ( $line =~ /^\*?\s+.*\s+($CISCO_MAC)\s+dynamic\s+\S+\s+\S+\s+(\S+)\s+$/o ) {
	    $mac   = $1;
	    $iname = $2;
	}else{
	    $logger->debug(sub{"Device::CiscoIOS::_get_fwt_from_cli: line did not match criteria: $line" });
	    next;
	}

	my $intid = $int_names{$iname};

	unless ( $intid ) {
	    $logger->warn("Device::CiscoIOS::_get_fwt_from_cli: $host: Could not match $iname to any interface names");
	    next;
	}
	
	my $validmac = PhysAddr->validate($mac);
	if ( $validmac ){
	    $mac = $validmac;
	}else{
	    $logger->debug(sub{"Device::CiscoIOS::_get_fwt_from_cli: $host: Invalid MAC: $mac" });
	    next;
	}	

	# Store in hash
	$fwt{$intid}{$mac} = 1;
	$logger->debug(sub{"Device::CiscoIOS::_get_fwt_from_cli: $host: $iname -> $mac" });
    }
    
    return \%fwt;
}


############################################################################
# Get CLI login credentials from config file
#
# Arguments: 
#   host
# Returns:
#   hashref
#
sub _get_credentials {
    my ($self, %argv) = @_;

    my $config_item = 'DEVICE_CLI_CREDENTIALS';
    my $host = $argv{host};
    my $cli_cred_conf = Netdot->config->get($config_item);
    unless ( ref($cli_cred_conf) eq 'ARRAY' ){
	$self->throw_user("Device::CiscoIOS::_get_credentials: config $config_item must be an array reference.");
    }
    unless ( @$cli_cred_conf ){
	$self->throw_user("Device::CiscoIOS::_get_credentials: config $config_item is empty");
    }

    my $match = 0;
    foreach my $cred ( @$cli_cred_conf ){
	my $pattern = $cred->{pattern};
	if ( $host =~ /$pattern/ ){
	    $match = 1;
	    my %args;
	    $args{login}      = $cred->{login};
	    $args{password}   = $cred->{password};
	    $args{privileged} = $cred->{privileged};
	    $args{transport}  = $cred->{transport} || 'SSH';
	    $args{timeout}    = $cred->{timeout}   || '30';
	    return \%args;
	}
    }   
    if ( !$match ){
	$logger->warn("Device::CiscoIOS::_get_credentials: $host did not match any patterns in configured credentials.");
    }
    return;
}

############################################################################
# Issue CLI command
#
# Arguments: 
#   command
# Returns:
#   array
#
sub _cli_cmd {
    my ($self, %argv) = @_;
    my ($login, $password, $privileged, $transport, $timeout, $host, $cmd) = 
	@argv{'login', 'password', 'privileged', 'transport', 'timeout', 'host', 'cmd'};
    
    $self->throw_user("Device::CiscoIOS::_cli_cmd: $host: Missing required parameters: login/password")
	unless ( $login && $password && $cmd );
    
    my @output;
    eval {
	$logger->debug(sub{"$host: issuing CLI command: '$cmd' over $transport"});
	my $s = Net::Appliance::Session->new(
	    Host      => $host,
	    Transport => $transport,
	    );
	
	$s->do_paging(0);
	
	$s->connect(Name      => $login, 
		    Password  => $password,
		    SHKC      => 0,
		    Opts      => [
			'-o', "ConnectTimeout $timeout",
			'-o', 'CheckHostIP no',
			'-o', 'StrictHostKeyChecking no',
		    ],
	    );
	
	if ( $privileged ){
	    $s->begin_privileged($privileged);
	}
	$s->cmd('terminal length 0');
	@output = $s->cmd(string=>$cmd, timeout=>$timeout);
	$s->cmd('terminal length 36');

	if ( $privileged ){
	    $s->end_privileged;
	}
	$s->close;
    };
    if ( my $e = $@ ){
	$self->throw_user("Device::CiscoIOS::_cli_cmd: $host: $e");
    }
    return @output;
}

############################################################################
# _reduce_name
#  Convert "GigabitEthernet0/3 into "Gi0/3" to match the different formats
#
# Arguments: 
#   string
# Returns:
#   string
#
sub _reduce_iname{
    my ($self, $name) = @_;
    return unless $name;
    $name =~ s/^(\w{2})\S*?([\d\/]+)$/$1$2/;
    return $name;
}