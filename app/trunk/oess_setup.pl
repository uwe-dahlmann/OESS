#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use OESS::Database;
use Sys::Hostname;
use Data::Dumper;
use CPAN;
sub main{

    system('clear');
    print "******************************\n";
    print "* OESS Software Setup Script *\n";
    print "******************************\n";

    print "NOTE: This should ONLY be run for a fresh install of OESS, if you have an\n";
    print "existing OESS install, please run the upgrade scripts in the upgrade\n";
    print "directory '/usr/share/oess/upgrade'\n";
    print "\nPress control+c to exit out of the installation process at any time\n";
    print "\n\nMySQL should be running, and you should know the administrator password\n";
    print "before continuing on.";
    print "\n";
    continue_param("Do you wish to continue");

    my $restart_dbus = yes_or_no_parameter("Do you want to restart DBus?");
    if($restart_dbus eq 'y'){
	`/etc/init.d/messagebus`;
    }else{
	
    }
    
    eval {
	require SOAP::Data::Builder;
    };

    if( $@ ){
	CPAN::Shell->install("SOAP::Data::Builder");
    }

    require SOAP::Data::Builder;

    eval { require Term::ReadKey; };

    if( $@ ){
	CPAN::Shell->install("Term::ReadKey");
    }

    use Term::ReadKey;
    print "\n\n\n";
    print "#####################################";
    print "\n\n  Starting Configuration of OESS\n\n";
    print "#####################################\n";

    print "\n\nDatabase Configuration\n";
    print "----------------------\n";
    my $db_host = optional_parameter("Host","127.0.0.1");
    my $db_port = optional_parameter("Port",3306);
    my $db_user = optional_parameter("Admin user","root");
    my $db_name = "oess";
    my $db_pass;
   
    ReadMode('noecho');
    while(!($db_pass = required_parameter("Admin Password: "))){
	print "\nAdmin Password is required\n\n";
    }
    ReadMode('normal');
    print "\n";
    
    my $host = hostname;
    my $oscars_host = optional_parameter("Oscars Host URL","https://$host");
    my $my_cert = optional_parameter("OSCARS SSL Cert","mycert.crt");
    my $my_key = optional_parameter("OSCARS SSL Key","mykey.key");
    my $topo_host = optional_parameter("TopoHost","http://ndb7.net.internet2.edu:8012/perfSONAR_PS/services/topology");

    print "\nTesting DB connection\n";
    my $handle = DBI->connect("DBI:mysql:dbname=mysql;host=$db_host;port=$db_port",
			      $db_user,
			      $db_pass,{PrintError => 0});

    if(!$handle){
	print "Failed!\n\n";
	print "Unable to connect to the DB: " . $DBI::errstr . "\n";
	exit(1);
    }else{
	print "DB Connection appears to work!\n";
    }

    continue_param("Do you want to create the database $db_name and install the OESS schema there?");
    print "The Follwing password requests are for the new mysql oess and snapp users that will be created\n";
    my $oess_pass;
    ReadMode('noecho');
    while(!($oess_pass = required_parameter("OESS Password: "))){
        print "\nOESS Password is required\n\n";
    }

    print "\n";

    my $snapp_pass;
    while(!($snapp_pass = required_parameter("SNAPP Password: "))){
        print "\nSNAPP Password is required\n\n";
    }
    ReadMode('normal');
    print "\n";

    print "\nCreating new users\n";
    
    $handle->do('create database oess');
    $handle->do('create database snapp');
    $handle->do("GRANT ALL ON oess.* to 'oess'\@'localhost' identified by '$oess_pass'") or die DBI::errstr;
    $handle->do("GRANT ALL ON snapp.* to 'snapp'\@'localhost' identified by '$snapp_pass'") or die DBI::errstr;
    $handle->do("flush privileges");
    
    #put all of this into a config file
    print "Creating Configuration file (/etc/oess/database.xml)\n";
    open(FILE, "> /etc/oess/database.xml");
    
    print FILE << "END";
<config snapp_config_location="/SNMP/snapp/snapp_config.xml" host="$db_host" port="$db_port">
  <credentials username="oess" password="$oess_pass" database="oess" />
  <oscars host="$oscars_host" cert="$my_cert" key="$my_key" topo="$topo_host"/>
</config>
END

close(FILE);
    print "\nInstalling the OESS Schema\n";
    my $db = OESS::Database->new();
    $OESS::Database::ENABLE_DEVEL=1;
    $db->reset_database();

    print "DONE!\n\n";
    print "Re-connecting to mysql using the new database ($db_name)... ";

    $handle = DBI->connect("DBI:mysql:dbname=$db_name;host=$db_host;port=$db_port",
                       $db_user,
                       $db_pass,
                       {PrintError => 0});

    if (!$handle) {
	print "FAILED!\n\n";
	print "Unable to connect to the database: " . $DBI::errstr . "\n";
	exit(1);
    }else {
	print "OK!\n\n";
    }
    
    
    #create local domain
    my $domain_name = required_parameter("What is your local domain (Fully Qualified)");
    
    my $sth = $handle->prepare("insert into network (name,longitude,latitude,is_local) VALUES (?,?,?,?)") or die "Unable to add Network";
    $sth->execute($domain_name,0,0,1) or die "Unable to add Network";

    #ok now install the SNAPP DB
    $handle->func('createdb',"snappdb",'admin');
    
    my $sql_file = "";
    while($sql_file eq '' || !-e $sql_file){
	$sql_file = optional_parameter("Location of snapp.mysql.sql","/usr/share/doc/snapp-collector-3.0.12/sql/snapp.mysql.sql");
    }

    system("mysql -u\"$db_user\" -p\"$db_pass\" -h\"$db_host\" -P\"$db_port\" \"snapp\" < $sql_file");
    
    print "DONE!\n\n";
    print "Re-connecting to mysql using the new database ($db_name)... ";
    
    $handle = DBI->connect("DBI:mysql:dbname=snapp;host=$db_host;port=$db_port",
			   $db_user,
			   $db_pass,
			   {PrintError => 0});
    
    if (!$handle) {
        print "FAILED!\n\n";
        print "Unable to connect to the database: " . $DBI::errstr . "\n";
	exit(1);
    }else {
        print "OK!\n\n";
    }

    $handle->do("GRANT ALL PRIVILEGES ON snapp.* to 'snapp'\@'localhost'");
    $sql_file = "";
    while($sql_file eq '' || !-e $sql_file){
        $sql_file = optional_parameter("Location of SNAPPs base_example.sql","/usr/share/doc/snapp-collector-3.0.12/sql/base_example.sql");
    }

    system("mysql -u\"$db_user\" -p\"$db_pass\" -h\"$db_host\" -P\"$db_port\" \"snapp\" < $sql_file");
    
    #put all of this into a config file
    `/bin/mkdir -p /SNMP/snapp`;
    open(FILE, "> /SNMP/snapp/snapp_config.xml");
    print FILE << "END";
<snapp-config>
  <db type="mysql" name="snapp" username="snapp" password="$snapp_pass" port="3306" host="localhost" collection_class_name="PerVlanPerInterface">
  </db>
  <control port="9967" enable_password="control-caos"></control>
</snapp-config>
END

close(FILE);

    #setup our new collection_class
    my $base_path = optional_parameter("What path do you want the RRD files stored?","/SNMP/snapp/db/");
    `/bin/mkdir $base_path`;
    `/bin/chown _snapp:_snapp $base_path -R`;
    my $sth3 = $handle->prepare("update global set value = ? where name = 'rrddir'");
    $sth3->execute($base_path);

    my $step = optional_parameter("What interval do you want to collect per VLAN per Interface statistics?",10);

    $sth = $handle->prepare("insert into collection_class (name,description,collection_interval,default_cf,default_class) VALUES ('PerVlanPerInterface','FlowStats',?,'AVERAGE',0)");
    $sth->execute($step);
    my $collection_class_id = $handle->{'mysql_insertid'};
    
    $sth = $handle->prepare("select * from oid_collection where name = 'in-octets' or name = 'out-octets' or name = 'in-packets' or name = 'out-packets'");
    $sth->execute();
    
    while(my $row = $sth->fetchrow_hashref()){
	my $ds_name = "";
	if($row->{'name'} eq 'in-packets'){
	    $ds_name = "inUcast";
	}elsif($row->{'name'} eq 'out-packets'){
	    $ds_name = "outUcast";
	}elsif($row->{'name'} eq 'in-octets'){
	    $ds_name = "input";
	}else{
	    $ds_name = "output";
	}

	my $sth2 = $handle->prepare("insert into oid_collection_class_map (collection_class_id,oid_collection_id,order_val,ds_name) VALUES (?,?,20,?)") or die "Unable to prepare query: " . DBI::errstr;
	$sth2->execute($collection_class_id,$row->{'oid_collection_id'},$ds_name) or die "Unable to execute query: " . DBI::errstr;

    }


    my $another = 1;
    while($another){
	print "Setting up the RRAs... this is how to consolidate, and how long to keep data";
	my $consolidation = optional_parameter("How many data points should I consolidate?",1);
	my $int = $step * $consolidation;
	my $how_long = optional_parameter("How long do you want to retain $int sec data? (days)",100);
	my $sth3 = $handle->prepare("insert into rra (collection_class_id,step,cf,num_days,xff) VALUES (?,?,?,?,?)");
	$sth3->execute($collection_class_id,$consolidation,'AVERAGE',$how_long,0.8);
	my $yes_no = yes_or_no_parameter("Do you want to add another RRA?");
	if($yes_no eq 'y'){
	    $another = 1;
	}else{
	    $another = 0;
	}
    }


    #create a user
    continue_param("OESS Frontend requires a user, would you like to add a user via htpasswd file?");
    
    my $user = required_parameter("UserName");
    my $pass = required_parameter("Password");
    
    open(FILE, "> /usr/share/oess-frontend/www/.htpasswd");
    print FILE $user . ":" . crypt($pass,$pass) . "\n";
    close(FILE);
    
    
}

sub required_parameter {

    my $name = shift;

    while (1) {

	print "$name (required): ";
	my $response = <>;
	chomp($response);

	return $response if ($response);

	print "\nThis option is required!\n\n";
    }
}


sub yes_or_no_parameter {

    my $name = shift;

    print "$name [y/n]: ";
    my $yes_or_no = <>;
    chomp($yes_or_no);

    if ($yes_or_no =~ /y/i && $yes_or_no !~ /n/i) {

	$yes_or_no = "y";
    }

    else {

	$yes_or_no = "n";
    }

    return $yes_or_no;
}

sub continue_param{
    my $name = shift;
    print "$name [y/n]: ";
    my $yes_or_no = <>;
    chomp($yes_or_no);
    
    exit(0) if ($yes_or_no !~ /y/i || $yes_or_no =~ /n/i);
}

sub optional_parameter {

    my ($name, $default) = @_;

    print $name;

    if (defined($default)) {

	print " [default $default]: ";
    }

    else {

	print ": ";
    }

    my $response = <>;
    chomp($response);

    $response = $default if (defined($default) && !$response);

    return $response;
}


main();



