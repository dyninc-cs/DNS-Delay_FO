#!/usr/bin/env perl


use warnings;
use strict;
use Config::Tiny;
use Getopt::Long;

#enable trapping of signals so the script exits gracefully when stopped
use sigtrap 'handler' => \&close_shop, qw(normal-signals);

#Import DynECT handler
use FindBin;
# use the parent directory
use lib $FindBin::Bin;
require DynECT::DNS_REST;

#constants
my $FO_URI = '/REST/Failover/';

#options variables
my ( $opt_host , $opt_zone , $opt_pri , $opt_back , $opt_delay , $opt_debug, $opt_help );

#grab CLI options
GetOptions( 
	'host=s'	=>	\$opt_host,
	'zone=s'	=>	\$opt_zone,
	'primary'	=>	\$opt_pri,
	'backup'	=>	\$opt_back,
	'delay=s'	=>	\$opt_delay,
	'debug'		=>	\$opt_debug,
	'help'		=>	\$opt_help,
);

#help text
if ( $opt_help ) {
	print "\tOptions:\n\n\t";
	printf("%-18s", '-zone');
	print "REQUIRED: Root zone which contains active failover service\n\t\t\t   to monitor\n\t";
	printf("%-18s", '-host');
	print "REQUIRED: Hostname with active failover service to monitor\n\t";
	printf("%-18s", '-delay');
	print "REQUIRED: Number of seconds to delay failover\n\t";
	printf("%-18s", '-primary');
	print "Set script to run in primary site mode, altering some timings\n\t";
	printf("%-18s", '-backup');
	print "Set script to run in backup site mode, altering some timings\n\t";
	printf("%-18s", '-debug');
	print "Log additional debug information to ./logs/bebug.log\n\t";
	printf("%-18s", '-help');
	print "Print this help information and exit\n";
	exit;
}

#check options for validity
unless ( $opt_host && $opt_zone ) {
	print "Options -host and -zone are required.  Please see -help for more information\n";
	exit;
}

unless ( $opt_pri xor $opt_back ) {
	print "Either option -primary or -backup is required.  Please see -help for more information\n";
	exit;
}

unless ( $opt_delay ) {
	print "A delay defined with -delay is required.  Please see -help for more information\n";
	exit;
}

#check that the host exists in the zone 
$opt_zone = lc ( $opt_zone );
$opt_host = lc ( $opt_host );
unless ( $opt_host =~ /$opt_zone/ ) {
	die "Hostname and zone do not match.  Please see -help for more information\n"
}

#open the config file
my $cfg = Config::Tiny->read( 'config.cfg' );

#dump config variables into hash
my %configopt;
$configopt{'cn'} = $cfg->{login}->{cn};
$configopt{'un'} = $cfg->{login}->{un};
$configopt{'pw'} = $cfg->{login}->{pw};

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

#initialize DynECT handler
my $dynect = DynECT::DNS_REST->new;

#attempt to login
$dynect->login( $apicn, $apiun, $apipw) 
	or die "Unable to log in to the DynECT API.  Please check your login credentials and internet availability\n";

#create local scope to trash test variables outside of loop
{
	#test existence of zone and Active Failover on hostname
	$dynect->request( "/REST/Zone/$opt_zone", 'GET' ) 
		or die "Could not retrieve information for $opt_zone.  Please check configuration of that zone name\n";
	my %api_test_param = ( detail => 'N' );
	$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'GET', \%api_test_param ) 
		or die "Could not find Active Failover for $opt_host.  Please check configuration of that hostname\n";
}

#logout of test session
$dynect->logout;

#create log directory if it does not already exist
mkdir "$FindBin::Bin/logs" unless ( -d "$FindBin::Bin/logs" );

#open logfile
my $fh_log;
#create local scope to create temporary variable
{
	my $temp = $opt_host;
	$temp =~ s/\./_/g;
	open ( $fh_log, '>>', "$FindBin::Bin/logs/log_$temp.log") 
		or die "Unable to open file at $FindBin::Bin/logs/log_$temp.log\n";
}
#write startup to log
if ( $opt_pri ) {
	print $fh_log time . " - Startup in primary mode and monitoring active failover at $opt_host";
}
else {
	print $fh_log time . " - Startup in backup mode and monitoring active failover at $opt_host";
}
print $fh_log ". Debug mode enabled" if $opt_debug;
print $fh_log "\n";

#initiate loop
my $loop_sleep = 10;
while ( 1 ) { 
	print $fh_log time . " - Loop start, sleeping for $loop_sleep seconds\n" if $opt_debug;

	#flush the print buffers once every loop
	{
	
		my $temp_fh = select $fh_log;
		$| = 1;
		print $fh_log "";
		$| = 0;
		select $temp_fh;
	}

	sleep $loop_sleep;

	#API login
	$dynect->login( $apicn, $apiun, $apipw ) or do {
		#if we can't login, go to sleep for a minute
		$loop_sleep = 60;
		print $fh_log time . " - Unable to login to DynECT API.  Sleeping for 60 seconds\n";
		next; 
	};

	#check Active Failover
	my %api_param = ( detail => 'N' );
	$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'GET', \%api_param ) or do {
		$loop_sleep = 30;
		print $fh_log time . " - Unable to retrieve information for active failover at $opt_host.  Retry in $loop_sleep seconds\n";
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
	$loop_sleep = ( $last_check + $interval ) - $time + 20;
	#second check in case local time is off
	$loop_sleep = $interval + int(rand(20)) if ( ( $loop_sleep > ( $interval + 20 )) || ( $loop_sleep < 1 ) );

	print $fh_log time . " - Current interval set to $interval.  New sleep time calculated to $loop_sleep\n" if $opt_debug;

	if ( $dynect->response->{'data'}{'status'} eq 'failover' ) {
		#logic if the Active Failover is currently in failover state
		print $fh_log time . " - Failover at $opt_host currently detected to be in failover mode\n" if $opt_debug;
		#if the CNAME is already in failure, loop again
		if ( $dynect->response->{'data'}{'failover_data'} eq ( 'back.' . $opt_host  ) ) {
			print $fh_log time . " - Failover record already set to back.$opt_host\n" if $opt_debug;
			$dynect->logout;
			next;
		}
		else { 
			#logout if given long delay
			$dynect->logout if ( $opt_delay > 120 );
			#wait for the delay to expire
			my $wait = $opt_delay;
			#preference the backup site to do the work
			$wait = $wait + 20 if $opt_pri;
			print $fh_log time . " - Possible failover event detected.  Entering delay mode for $opt_delay seconds\n";
			sleep $opt_delay if ($opt_delay > 0);
			#log back in if given long delay
			if ( $opt_delay > 120 ) {
				$dynect->login or do {
					$loop_sleep = 30;
					print $fh_log time . "Failed to log in to API during possible failover event.  Will rety in $loop_sleep seconds\n";
					next;
				}
			}
			#check if still down
			%api_param = ( detail => 'N' );
			$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'GET', \%api_param ) or do {
				$dynect->logout;
				next;
			};
			#loop if it has recovered
			if ( $dynect->response->{'data'}{'status'} ne 'failover' ) {
				print $fh_log time . " - Leaving delay mode. Service has recovered, no action taken.\n"; 
				$dynect->logout;
				next;
			};

			#ensure work hasn't already been done
			if ( $dynect->response->{'data'}{'failover_data'} eq ( 'back.' . $opt_host ) ) {
				print $fh_log time . " - Leaving delay mode.  Record change completed by different instance or manual intervention\n";
				$dynect->logout;
				next;
			}

			print $fh_log time . " - Leaving delay mode.  Service still in failover, processing change\n" if $opt_debug;
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
			#update CNAME in FO
			$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'PUT', \%api_param ) or do {
				$loop_sleep = 30;
				print $fh_log time . " - Failed to process record change.  Will retry in $loop_sleep\n";
				$dynect->logout;
				next;
			};

			print $fh_log time . " - Record change complete\n";
		}	
	}	
	elsif ( $dynect->response->{'data'}{'status'} eq 'ok' ) {
		#logic if the FO is in 'OK' state
		#if the CNAME is already in primary, loop again
		print $fh_log time . " - Failover at $opt_host currently detected to be in primary mode\n" if $opt_debug;
		if ( $dynect->response->{'data'}{'failover_data'} eq ( 'pri.' . $opt_host  ) ) {
			print $fh_log time . " - Failover record already set to pri.$opt_host\n" if $opt_debug;
			$dynect->logout;
			next;
		}
		else { 
			print $fh_log time . " - Failover service recovery detected\n";
			#preference the primary site to do the work
			if ( $opt_back ) { 
				print $fh_log time . " - Entering 20 second delay mode prior to recovery for backup site mode\n" if $opt_debug;
				sleep 20;
				#check if still down
				print $fh_log time . " - Leaving delay mode.  Rechecking service\n";
				%api_param = ( detail => 'N' );
				$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'GET', \%api_param ) or do {
					$loop_sleep = 30;
					print $fh_log time . " - Unable to retireve service status during recovery mode.  Retry in $loop_sleep seconds\n";
					$dynect->logout;
					next;
				};
				#loop if FO has re-failed
				if ( $dynect->response->{'data'}{'status'} eq 'failover' ) {
					print $fh_log time . " - Service has re-entered failure state.  No changes completed\n";
					$dynect->logout;
					next;
				};
				#ensure work hasn't already been done
				if ( $dynect->response->{'data'}{'failover_data'} eq ( 'pri.' . $opt_host ) ) {
					print $fh_log time . " - Failover recrod recovery completed by different instance or manual intervention.\n";
					$dynect->logout;
					next;
				}
			}

			print $fh_log time . " Processing failover record recovery change\n" if $opt_debug;
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
			#change failover CNAME back to OK state
			$dynect->request( $FO_URI . "$opt_zone/$opt_host" , 'PUT', \%api_param ) or do {
				$loop_sleep = 30;
				print $fh_log time . " - Unable to complete failover record recovery change.  Retry in $loop_sleep\n";
				$dynect->logout;
				next;
			};
			print $fh_log time . " - Failover record revocery completed successfully\n";
		}
	}
	else {
		print $fh_log time . "Active Failover status unknon.  Will retry in $loop_sleep\n" if $opt_debug;
	}	
	$dynect->logout;
}

#interupt handler
sub close_shop {
	#close the file handle
	close $fh_log;
	#logout of any sessions
	$dynect->logout;
	exit;
}

