#!/usr/bin/perl
#------ NDDI OESS Measurement Module
##-----
##----- $HeadURL: svn+ssh://svn.grnoc.iu.edu/grnoc/oe-ss/perl-lib/OESS-Measurement/tags/1.0.0/lib/OESS/Measurement.pm $
##----- $Id$
##----- $Date$
##----- $LastChangedBy$
##-----
##----- Provides object oriented methods to interact with the DBus test             
##----------------------------------------------------------------------
##                                                                                       
## Copyright 2011 Trustees of Indiana University                                         
##                                                                                       
##   Licensed under the Apache License, Version 2.0 (the "License");                     
##  you may not use this file except in compliance with the License.                     
##   You may obtain a copy of the License at                                             
##                                                                                       
##       http://www.apache.org/licenses/LICENSE-2.0                                      
##                                                                                       
##   Unless required by applicable law or agreed to in writing, software                 
##   distributed under the License is distributed on an "AS IS" BASIS,                   
##   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.            
##   See the License for the specific language governing permissions and                 
##   limitations under the License.                                                      
#                                                 


package OESS::Measurement;

use strict;
use warnings;

use RRDs;
use XML::Simple;
use OESS::Database;
use Data::Dumper;
use Exporter qw(import);

use constant BUILDING_FILE => -1;

our @EXPORT_OK = qw(BUILDING_FILE);

our $VERSION = '1.0.0';

our $ENABLE_DEVEL=0;


sub new{
    my $that = shift;
    my $class = ref($that) || $that;


    my $db = OESS::Database->new();

    if(!defined($db)){
        return undef;
    }

    my %args = (
	config => $db->get_snapp_config_location(),
	@_
	);
    
    
    my $self = \%args;
    bless $self,$class;

    $self->{'db'} = $db;

    my $config_filename = $args{'config'};
    my $config = XML::Simple::XMLin($config_filename);

    my $username = $config->{'db'}->{'username'};
    my $password = $config->{'db'}->{'password'};
    my $database = $config->{'db'}->{'name'};
    my $dbh = DBI->connect("DBI:mysql:$database", $username, $password);
    
    $self->{'dbh'} = $dbh;
    
    return $self;
    
}

sub _set_error {
    my $self = shift;
    my $error = shift;
    
    $self->{'error'} = $error;
}

sub get_error{
    my $self = shift;

    my $err = $self->{'error'};
    $self->{'error'} = undef;
    return $err;
}

=head2 get_circuit_data
  Params: circuit_id => circuit id of the circuit to find data for
          start_time => the start_time to get data for
          end_time => the end time to get data for (optional, if not defined is set to NOW)

  return RRD Data
=cut

sub get_circuit_data{
    my $self = shift;
    my %params = @_;

    if(!defined($params{'circuit_id'})){
	$self->_set_error("circuit_id is required");
	return undef;
    }

    if(!defined($params{'start_time'})){
	$self->_set_error("start_time is required and should be in epoch time");
	return undef;
    }

    if(!defined($params{'end_time'})){
	
    }

    #find the base RRD dir
    my $rrd_dir;
    my $query = "select value from global where name = 'rrddir'";
    my $sth = $self->{'dbh'}->prepare($query);
    $sth->execute();
    if(my $row = $sth->fetchrow_hashref()){
	$rrd_dir = $row->{'value'};
    }

    #find the circuits first endpoing                                                                                                                    
    my $ints = $self->{'db'}->get_circuit_endpoints(circuit_id => $params{'circuit_id'});

    # reorder them to make sure we always get the same interface
    my @sorted = sort { $a->{'interface'} <=> $b->{'interface'} } @$ints;

    my $int_a = $sorted[0];

    # make sure we're looking at the local end
    if ($int_a->{'local'} eq 0){
	$int_a = $sorted[1];
    }

    #get all the host details for the interfaces host
    my $host = $self->get_host_by_external_id($int_a->{'node_id'});
    
    #find the collections RRD file in SNAPP
    my $collection = $self->_find_rrd_file_by_host_int_and_vlan($host->{'host_id'},$int_a->{'interface'},$int_a->{'tag'});
    if(defined($collection)){
	my $rrd_file = $rrd_dir . $collection->{'rrdfile'};
	return $self->get_rrd_file_data( file => $rrd_file, start_time => $params{'start_time'}, end_time => $params{'end_time'});
    }else{
	#unable to find RRD file
	$self->_set_error("Unable to find RRD/Collection");
	return BUILDING_FILE;#[{name => 'Creating RRD', data => [[time(), undef]]}];
    }
}

sub _find_rrd_file_by_host_and_int{
    my $self = shift;
    my $host_id = shift;
    my $int_name = shift;

    my $query = "select * from collection where host_id = ? and premap_oid_suffix = ?";
    my $sth = $self->{'dbh'}->prepare($query);
    $sth->execute($host_id,"Ethernet" . $int_name);
    if(my $row = $sth->fetchrow_hashref()){
	return $row;
    }else{
	$self->_set_error("No Collection found with host_id $host_id and interface name $int_name\n");
	return undef;
    }
}

sub _find_rrd_file_by_host_int_and_vlan{
    my $self = shift;
    my $host_id = shift;
    my $port = shift;
    my $vlan = shift;

    # openflow treats untagged as 0xFFFF so that's
    # what we'll need to look for
    if ($vlan eq -1){
        $vlan = 65535;
    }    

    my $query = "select * from collection where host_id = ? and premap_oid_suffix = ?";
    my $sth = $self->{'dbh'}->prepare($query);
    $sth->execute($host_id,$port . "-" . $vlan);
    if(my $row = $sth->fetchrow_hashref()){
	return $row;
    }else{
	$self->_set_error("No Collection found for host host_id with interface and vlan $port - $vlan");
	return undef;
    }
}

=head2 get_host_by_external_id

    find a host based on the external_id (ie... node_id)

=cut



sub get_host_by_external_id{
    my $self = shift;
    my $id = shift;
    
    my $query = "select * from host where host.external_id = ?";
    my $sth = $self->{'dbh'}->prepare($query);
    $sth->execute($id);
    if(my $row = $sth->fetchrow_hashref()){
	return $row;
    }else{
	$self->_set_error("No host found with external_id $id");
	return undef;
    }
}



=head2 get_rrd_file_data

    Params: file => the rrd file to pull data from
            start_time => the start time (epoch or RRD style (-5min))
            end_time => (optional) the end time to query data for (epoch or RRD style NOW) defaults to NOW if not specified

    process the data into a format for the FLOT graphs to use, also buckets data so that javascript doesn't freak out with too much data

=cut

sub get_rrd_file_data{
    my $self = shift;
    my %params = @_;

    if(!defined($params{'file'})){
	$self->_set_error("No file specified");
	return undef;
    }

    if(!defined($params{'start_time'})){
	$self->_set_error("No Start time specified");
	return undef;
    }

    if(!defined($params{'end_time'})){
	$params{'end_time'} = "NOW";
    }

    if(!defined($params{'h_size'})){
	$params{'h_size'} = 300;
    }

    my ($start,$step,$names,$data) = RRDs::fetch($params{'file'},"AVERAGE","-s " . $params{'start_time'},"-e " . $params{'end_time'});

    if (! defined $data){
	return undef;
    }
    
    my @results;
    my $output;
    my $input;
    my @names = @$names;
    my @data = @$data;

    for(my $i=0;$i<$#names;$i++){

	if($names[$i] eq 'output'){
	    $output = $i;
	}elsif($names[$i] eq 'input'){
	    $input = $i;
	}
    }
    my $time = $start;
    my @outputs;
    my @inputs;

    my $spacing = int(@$data / $params{'h_size'});
    $spacing = 1 if($spacing == 0);

    for(my $i=0;$i<$#data;$i+=$spacing){
	my ($bucket,$j);

	for($j = 0;$j<$spacing && $j+$i < @$data; $j++){
	    my $row = @$data[$i+$j];
	    my $divisor = ($j + $i == @$data - 1? $j+1 : $spacing);
	    
	    if(defined(@$row[$input])){
		$bucket->{'input'} += @$row[$input] / $divisor;
	    }
	    
	    if(defined(@$row[$output])){
		$bucket->{'output'} += @$row[$output] / $divisor;
	    }
	}
	
	if($spacing > 1){
	    my $timeStart = $start;
	    my $timeEnd = ($start + ($step*$spacing));
	    $bucket->{'time'} = ($timeStart + $timeEnd) / 2;
	}else{
	    $bucket->{'time'} = $start;
	}

	$start += ($step * $spacing);
	if(defined($bucket->{'input'})){
	    $bucket->{'input'} *= 8;
	}
	push(@inputs,[$bucket->{'time'}, $bucket->{'input'}]);
	if(defined($bucket->{'output'})){
	    $bucket->{'output'} *= 8;
	}
	push(@outputs,[$bucket->{'time'}, $bucket->{'output'}]);

    }

    push(@results,{"name" => "Input (bps)",
		   "data" => \@inputs});
    push(@results,{"name" => "Output (bps)",
		   "data" => \@outputs});

    return \@results;    
}


1;
