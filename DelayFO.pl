#!/usr/bin/env perl


use warnings;
use strict;
use Config::Simple;
use Getopt::Long;
use Data::Dumper;

#Import DynECT handler
use FindBin;
use lib $FindBin::Bin;  # use the parent directory
require DynECT::DNS_REST;

#contants
my $FO_URI = '/REST/Failover/';

#options variables
my ( $opt_host , $opt_zone , $opt_pri , $opt_back , $opt_delay , $opt_help );

#grab CLI options
GetOptions( 
	'host=s'	=>	\$opt_host,
	'zone=s'	=>	\$opt_zone,
	'primary'	=>	\$opt_pri,
	'backup'	=>	\$opt_back,
	'delay=s'	=>	\$opt_delay,
	'help'		=>	\$opt_help,
);

if ( $opt_help ) {
	print "Options:\n";
	exit;
}

$opt_zone = lc ( $opt_zone );
$opt_host = lc ( $opt_host );


#Create config reader
my $cfg = new Config::Simple();
# read configuration file (can fail)
$cfg->read('config.cfg') or die $cfg->error();

#dump config variables into hash
my %configopt = $cfg->vars();

#simple error checking
if ( ( $configopt{'cn'} eq 'custname' ) || ( $configopt{'un'} eq 'username' ) ) {
	print "Please update config.cfg configuration file with account information for API access\n";
	exit;
}

my $apicn = $configopt{'cn'} or do {
	print "Customer Name required in config.cfg for API login\n";
	exit;
};

my $apiun = $configopt{'un'} or do {
	print "User Name required in config.cfg for API login\n";
	exit;
};

my $apipw = $configopt{'pw'} or do {
	print "User password required in config.cfg for API login\n";
	exit;
};

my $dynect = DynECT::DNS_REST->new;

my $loop_sleep = 1;
while ( 1 ) { 
	sleep $loop_sleep;

	#API login
	$dynect->login( $apicn, $apiun, $apipw) or do {
		#if we can't login, go to sleep for a minute
		$loop_sleep = 60;
		next; 
	};

	my %api_param = ( detail => 'N' );
	$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'GET', \%api_param ) or do {
		$dynect->logout;
		next;
	};

	#check last time monitors ran
	my $last_check;
	foreach my $hashref ( @{$dynect->response->{'data'}{'log'}} ) {
		if ( defined $last_check ) {
			$last_check = $hashref->{'time'} if ( $hashref->{'time'} > $last_check );
		}
		else {
			$last_check = $hashref->{'time'};
		}
	}

	#align loops slightly offset of interval
	my $interval = $dynect->response->{'data'}{'monitor'}{'interval'} * 60;
	my $time = time;
	if ( ( $time - $last_check ) > $interval ) {
		$loop_sleep = 60;
	}
	else {
		$loop_sleep = $interval - ( $time - $last_check ) + 20;
	}
	print "Last run was at $last_check\nCurrent Time is $time\n";
	print "Interval is $interval\nNew sleep time is $loop_sleep\n";

	if ( $dynect->response->{'data'}{'status'} eq 'failover' ) {
		#if the CNAME is already in failure, loop again
		print "Checking Failover status\n";
		if ( $dynect->response->{'data'}{'failover_data'} eq ( 'back.' . $opt_host  ) ) {
			$dynect->logout;
			next;
		}
		else { 
			print "Work needs to be done\n";
			#logout if given long delay
			$dynect->logout if ( $opt_delay > 120 );
			#wait for the delay to expire
			my $wait = $opt_delay;
			#preference the backup site to do the work
			$wait = $wait + 20 if $opt_pri;
			while ( $wait > 120 ) {
				#send keep alive every 2 minutes
				sleep 120;
				$wait = $wait - 120;
			}
			#sleep remainder of delay
			print "Sleeping for $wait\n";
			sleep( $wait ) if ( $wait > 0 );
			print "Done waiting\n";
			#log back in if given long delay
			if ( $opt_delay > 120 ) {
				$dynect->login or next;
			}
			#check if still down
			%api_param = ( detail => 'N' );
			$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'GET', \%api_param ) or do {
				$dynect->logout;
				next;
			};
			#loop if it has recovered
			if ( $dynect->response->{'data'}{'status'} ne 'failover' ) {
				$dynect->logout;
				next;
			};

			#ensure work hasn't already been done
			if ( $dynect->response->{'data'}{'failover_data'} eq ( 'back.' . $opt_host ) ) {
				$dynect->logout;
				next;
			}

			print "Work still to be done\n";
			%api_param = (
				address => $dynect->response->{'data'}{'address'},
				failover_mode => 'cname',
				failover_data => 'back.' . $opt_host ,
				monitor => {
					protocol => $dynect->response->{'data'}{'monitor'}{'protocol'},
					path => $dynect->response->{'data'}{'monitor'}{'path'},
					expected => $dynect->response->{'data'}{'monitor'}{'expected'},
					port => $dynect->response->{'data'}{'monitor'}{'port'},
					interval => $dynect->response->{'data'}{'monitor'}{'interval'},
					header => $dynect->response->{'data'}{'monitor'}{'header'},
					retries => $dynect->response->{'data'}{'monitor'}{'retries'},
				},
				contact_nickname => $dynect->response->{'data'}{'contact_nickname'},
			);

			$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'PUT', \%api_param ) or do {
				print Dumper $dynect->response;
				$dynect->logout;
				next;
			};
			print Dumper $dynect->response;
		}	
	}	
	else { 
		#if the CNAME is already in primary, loop again
		print "Checking Success status\n";
		if ( $dynect->response->{'data'}{'failover_data'} eq ( 'pri.' . $opt_host  ) ) {
			$dynect->logout;
			next;
		}
		else { 
			#preference the primary site to do the work
			if ( $opt_back ) { 
				print "Sleeping for 20\n";
				sleep 20;
				print "Done waiting\n";
				#check if still down
				%api_param = ( detail => 'N' );
				$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'GET', \%api_param ) or do {
					$dynect->logout;
					next;
				};
				#loop if it has failed
				if ( $dynect->response->{'data'}{'status'} eq 'failover' ) {
					$dynect->logout;
					next;
				};
				#ensure work hasn't already been done
				if ( $dynect->response->{'data'}{'failover_data'} eq ( 'pri.' . $opt_host ) ) {
					$dynect->logout;
					next;
				}
			}

			print "Work still to be done\n";
			%api_param = (
				address => $dynect->response->{'data'}{'address'},
				failover_mode => 'cname',
				failover_data => 'pri.' . $opt_host ,
				monitor => {
					protocol => $dynect->response->{'data'}{'monitor'}{'protocol'},
					path => $dynect->response->{'data'}{'monitor'}{'path'},
					expected => $dynect->response->{'data'}{'monitor'}{'expected'},
					port => $dynect->response->{'data'}{'monitor'}{'port'},
					interval => $dynect->response->{'data'}{'monitor'}{'interval'},
					header => $dynect->response->{'data'}{'monitor'}{'header'},
					retries => $dynect->response->{'data'}{'monitor'}{'retries'},
				},
				contact_nickname => $dynect->response->{'data'}{'contact_nickname'},
			);

			$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'PUT', \%api_param ) or do {
				print Dumper $dynect->response;
				$dynect->logout;
				next;
			};
			print Dumper $dynect->response;
		}	
	}	
	$dynect->logout;
}


#print Dumper $dynect->response;


