#!/usr/bin/perl

use strict;
use warnings;

package OESS::MPLS::Device::Juniper::MX;

use Template;
use Net::Netconf::Manager;
use Data::Dumper;

use constant FWDCTL_WAITING     => 2;
use constant FWDCTL_SUCCESS     => 1;
use constant FWDCTL_FAILURE     => 0;
use constant FWDCTL_UNKNOWN     => 3;

use GRNOC::Config;

use base "OESS::MPLS::Device";

sub new{
    my $class = shift;
    my %args = (
        @_
	);
    
    my $self = \%args;

    $self->{'logger'} = Log::Log4perl->get_logger('OESS.MPLS.Device.Juniper.MX.' . $self->{'mgmt_addr'});
    $self->{'logger'}->debug("MPLS Juniper Switch Created!");
    bless $self, $class;

    #TODO: make this automatically figure out the right REV
    $self->{'template_dir'} = "juniper/13.3R8";

    $self->{'tt'} = Template->new(INCLUDE_PATH => "/usr/share/doc/perl-OESS-1.2.0/share/mpls/templates/") or die "Unable to create Template Toolkit!";

    return $self;

}

sub disconnect{
    my $self = shift;

    $self->{'jnx'}->disconnect();
    $self->{'connected'} = 0;
    return;
}

sub get_system_information{
    my $self = shift;

    my $reply = $self->{'jnx'}->get_system_information();

    if($self->{'jnx'}->has_error){
        $self->{'logger'}->error("Error fetching system information: " . Data::Dumper::Dumper($self->{'jnx'}->get_first_error()));
        return;
    }

    my $system_info = $self->{'jnx'}->get_dom();
    my $xp = XML::LibXML::XPathContext->new( $system_info);
    $xp->registerNs('x',$system_info->documentElement->namespaceURI);     
    my $model = $xp->findvalue('/x:rpc-reply/x:system-information/x:hardware-model');
    my $version = $xp->findvalue('/x:rpc-reply/x:system-information/x:os-version');
    my $host_name = $xp->findvalue('/x:rpc-reply/x:system-information/x:host-name');
    my $os_name = $xp->findvalue('/x:rpc-reply/x:system-information/x:os-name');

    # We need to create know the root path for our xml requests. This path containd the version minus the last number block
    # (13.3R1.6 -> 13.3R1). The following regex creates the path as described
    my $var = $version;
    $var =~ /(\d+\.\d+R\d+)/;
    my $root_namespace = "http://xml.juniper.net/junos/".$1.'/';
    $self->{'root_namespace'} = $root_namespace;
    return {model => $model, version => $version, os_name => $os_name, host_name => $host_name};
}

sub get_interfaces{
    my $self = shift;

    my $reply = $self->{'jnx'}->get_interface_information();

    if($self->{'jnx'}->has_error){
	$self->set_error($self->{'jnx'}->get_first_error());
        $self->{'logger'}->error("Error fetching interface information: " . Data::Dumper::Dumper($self->{'jnx'}->get_first_error()));
        return;
    }

    my @interfaces;

    my $interfaces = $self->{'jnx'}->get_dom();
    my $path = $self->{'root_namespace'}."junos-interface";
    my $xp = XML::LibXML::XPathContext->new( $interfaces);
    $xp->registerNs('x',$interfaces->documentElement->namespaceURI);
    $xp->registerNs('j',$path);  
    my $ints = $xp->findnodes('/x:rpc-reply/j:interface-information/j:physical-interface');

    foreach my $int ($ints->get_nodelist){
	push(@interfaces, $self->_process_interface($int));
    }

    return \@interfaces;
}

sub _process_interface{
    my $self = shift;
    my $int = shift;
    
    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $int );
    my $path = $self->{'root_namespace'}."junos-interface";
    $xp->registerNs('j',$path);
    $obj->{'name'} = trim($xp->findvalue('./j:name'));
    $obj->{'admin_state'} = trim($xp->findvalue('./j:admin-status'));
    $obj->{'operational_state'} = trim($xp->findvalue('./j:oper-status'));
    $obj->{'description'} = trim($xp->findvalue('./j:description'));
    if(!defined($obj->{'description'}) || $obj->{'description'} eq ''){
	$obj->{'description'} = $obj->{'name'};
    } 

    return $obj;

}

sub remove_vlan{
    my $self = shift;
    my $ckt = shift;

    my $vars = {};
    $vars->{'circuit_name'} = $ckt->{'circuit_name'};
    $vars->{'interface'} = {};
    $vars->{'interface'}->{'name'} = $ckt->{'interface'};
    $vars->{'vlan_tag'} = $ckt->{'vlan_tag'};
    $vars->{'primary_path'} = $ckt->{'primary_path'};
    $vars->{'backup_path'} = $ckt->{'backup_path'};
    $vars->{'circuit_id'} = $ckt->{'circuit_id'};
    $vars->{'switch'} = {name => $self->{'name'}};
    $vars->{'site_id'} = $self->{'node_id'};

    my $output;
    my $remove_template = $self->{'tt'}->process( $self->{'template_dir'} . "/ep_config_delete.xml", $vars, \$output) or warn $self->{'tt'}->error();

    return $self->_edit_config( config => $output );
}

sub add_vlan{
    my $self = shift;
    my $ckt = shift;
    
    $self->{'logger'}->error("Adding circuit: " . Data::Dumper::Dumper($ckt));

    my $vars = {};
    $vars->{'circuit_name'} = $ckt->{'circuit_name'};
    $vars->{'interface'} = {};
    $vars->{'interface'}->{'name'} = $ckt->{'interface'};
    $vars->{'vlan_tag'} = $ckt->{'vlan_tag'};
    $vars->{'primary_path'} = $ckt->{'primary_path'};
    $vars->{'backup_path'} = $ckt->{'backup_path'};
    $vars->{'destination_ip'} = $ckt->{'destination_ip'};
    $vars->{'circuit_id'} = $ckt->{'circuit_id'};
    $vars->{'switch'} = {name => $self->{'name'}};
    $vars->{'site_id'} = $self->{'node_id'};
    
    my $output;
    my $remove_template = $self->{'tt'}->process( $self->{'template_dir'} . "/ep_config.xml", $vars, \$output) or warn $self->{'tt'}->error();
    
    return $self->_edit_config( config => $output );    
    
}

sub connect{
    my $self = shift;
    
    if($self->connected()){
	$self->{'logger'}->error("Already connected to device");
	return;
    }
    $self->{'logger'}->info("Connecting to device!");
    my $jnx = new Net::Netconf::Manager( 'access' => 'ssh',
					 'login' => $self->{'username'},
					 'password' => $self->{'password'},
					 'hostname' => $self->{'mgmt_addr'},
					 'port' => 22 );
    if(!$jnx){
	$self->{'connected'} = 0;
    }else{
	$self->{'logger'}->info("Connected!");
	$self->{'jnx'} = $jnx;
	#gather basic system information needed later!
	my $verify = $self->verify_connection();
	if ($verify == 1) {
	    $self->{'connected'} = 1;
	}
	else {
	    $self->{'connected'} = 0;
	}
    }


}

sub connected{
    my $self = shift;
    return $self->{'connected'};
}

sub verify_connection{
    #gather basic system information needed later, and make sure it is what we expected / are prepared to handle                                                                            
    #
    my $self = shift;
    my $sysinfo = $self->get_system_information();
    if (($sysinfo->{"os_name"} eq "junos") && ($sysinfo->{"version"} eq "13.3R1.6")){
	# print "Connection verified, proceeding\n";
	return 1;
    }
    else {
	$self->{'logger'}->error("Network OS and / or version is not supported");
	return 0;
    }
    
}

sub get_isis_adjacencies{
    my $self = shift;

    if(!defined($self->{'jnx'}->{'methods'}->{'get_isis_adjacency_information'})){
	my $TOGGLE = bless { 1 => 1 }, 'TOGGLE';
	$self->{'jnx'}->{'methods'}->{'get_isis_adjacency_information'} = { detail => $TOGGLE};
    }

    $self->{'jnx'}->get_isis_adjacency_information( detail => 1 );

    my $xml = $self->{'jnx'}->get_dom();
    warn Dumper($xml->toString());
    my $xp = XML::LibXML::XPathContext->new( $xml);
    $xp->registerNs('x',$xml->documentElement->namespaceURI);
    my $path = $self->{'root_namespace'}."junos-routing";
    $xp->registerNs('j',$path);

    my $adjacencies = $xp->find('/x:rpc-reply/j:isis-adjacency-information/j:isis-adjacency');
    
    my @adj;
    foreach my $adjacency (@$adjacencies){
	push(@adj, $self->_process_isis_adj($adjacency));
    }

    return \@adj;
}

sub _process_isis_adj{
    my $self = shift;
    my $adj = shift;

    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $adj );
    my $path = $self->{'root_namespace'}."junos-routing";
    $xp->registerNs('j',$path);
    $obj->{'interface_name'} = trim($xp->findvalue('./j:interface-name'));
    $obj->{'operational_state'} = trim($xp->findvalue('./j:adjacency-state'));
    $obj->{'remote_system_name'} = trim($xp->findvalue('./j:system-name'));
    $obj->{'ip_address'} = trim($xp->findvalue('./j:ip-address'));
    $obj->{'ipv6_address'} = trim($xp->findvalue('./j:ipv6-address'));

    return $obj;
}

sub get_LSPs{
    my $self = shift;

    $self->{'jnx'}->get_mpls_lsp();
    
    
    my @LSPs;

    return \@LSPs;
}

sub _edit_config{
    my $self = shift;
    my %params = @_;

    $self->{'logger'}->debug("Sending the following config: " . $params{'config'});

    if(!defined($params{'config'})){
	$self->{'logger'}->error("No Configuration specified!");
	return FWDCTL_FAILURE;
    }

    if(!$self->{'connected'}){
	$self->{'logger'}->error("Not currently connected to the switch");
	return FWDCTL_FAILURE;
    }
    
    my %queryargs = ( 'target' => 'candidate' );
    my $res = $self->{'jnx'}->lock_config(%queryargs);

    if($self->{'jnx'}->has_error){
	$self->{'logger'}->error("Error attempting to lock config: " . Dumper($self->{'jnx'}->get_first_error()));
	return FWDCTL_FAILURE;
    }

    %queryargs = (
        'target' => 'candidate'
        );

    $queryargs{'config'} = $params{'config'};
    
    $res = $self->{'jnx'}->edit_config(%queryargs);
    if($self->{'jnx'}->has_error){
	$self->{'logger'}->error("Error attempting to modify config: " . Dumper($self->{'jnx'}->get_first_error()));
	my %queryargs = ( 'target' => 'candidate' );
	$res = $self->{'jnx'}->unlock_config(%queryargs);
	return FWDCTL_FAILURE;
    }

    $self->{'jnx'}->commit();
    if($self->{'jnx'}->has_error){
	$self->{'logger'}->error("Error attempting to commit the config: " . Dumper($self->{'jnx'}->get_first_error()));
	my %queryargs = ( 'target' => 'candidate' );
        $res = $self->{'jnx'}->unlock_config(%queryargs);
	return;
    }

    my %queryargs = ( 'target' => 'candidate' );
    $res = $self->{'jnx'}->unlock_config(%queryargs);

    return FWDCTL_SUCCESS;
}

sub trim{
    my $s = shift; 
    $s =~ s/^\s+|\s+$//g;
    return $s
}

1;