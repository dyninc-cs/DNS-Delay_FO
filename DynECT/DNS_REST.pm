#!/usr/bin/env perl

package DynECT::DNS_REST;

$VERSION = "1.01";
$VERSION = eval $VERSION;

use strict;
use warnings;
use LWP::UserAgent;
use LWP::Protocol::https;
use JSON;

#TODO: Write documentation with POD
#TODO: Add hash to store error messag
#TODO: method to access last call
#TODO: debug mode

#Constructor
sub new {	
	#reference to self if first argument passed in
	my $classid = shift;
	my %con_args = @_;
	
	my $self = {
		#LWP User agent instance
		lwp => '',		
		apitoken => undef,
		apiver => undef,
		#Current status meesage
		message => '',
		#Reference to a hash for JSON decodes of most recent result
		resultref => '',
		lasturi => '',
		lastmethod => '',
		lastrc => '',
		lasterrortype => '',
	};

	$$self{'apiver'} = $con_args{ 'version' } if ( exists $con_args{ 'version' } );

	$$self{'lwp'} = LWP::UserAgent->new;
	#diable redirect following as that is a special case with DynECT
	$$self{'lwp'}->max_redirect( '0' );
	#reduce timeout from 180 seconds to 20
	$$self{'lwp'}->timeout( '20' );
	
	bless $self, $classid;

	return $self;
}

#API login an key generation
sub login {
	#get reference to self
	#get params from call
	my ($self, $custn, $usern, $pass) = @_;
	

	#API login
	my %api_param = (
		'customer_name' => $custn,
		'user_name' => $usern,
		'password' => $pass,
	);

	my $res = $self->request( 'OVERRIDESESSION', 'POST', \%api_param);
	if ( $res ) {
		$$self{'apitoken'} = $$self{'resultref'}{'data'}{'token'};
		$$self{'message'} = 'Session successfully created';
	}
	return $res;
}

sub keepalive {
	#get reference to self
	#get params from call
	my $self = shift @_;

	my $res = $self->request( 'OVERRIDESESSION', 'PUT');
	$$self{ 'message' } = "Session keep-alive successful" if $res;
	return $res;
}

sub logout {
	#get self id
	my $self = shift @_;
	#TODO: Set message if API token not set
	#existance of the API key means we are logged in
	if ( defined $$self{'apitoken'} ) {
		#Logout of the API, to be nice
		my $res = $self->request( 'OVERRIDESESSION', 'DELETE');
		if ( $res ) {
			$$self{ 'message' } = "Session logout successful";
			undef $$self{'apitoken'};
			$$self{'message'} = "Logout successful";
		}
		else {
			$$self{'message'} = "API Session not available for logout.  Please use ->login to create a session";
		}
		return $res;
	}
}

sub request {
	my ($self, $uri, $method, $paramref) = @_;
	if (defined $paramref) {
		#weak check for correct paramater type
		unless ( ref($paramref) eq 'HASH' ) {
			$$self{'message'} = "Invalid paramater type.  Please utilize a hash reference";
			return 0;
		}
	}


	unless ((( $uri eq 'OVERRIDESESSION' ) && ( uc( $method ) eq 'POST' )) || $$self{ 'apitoken' } ) {
		$$self{'message'} = "API Session required for this method.  Please use ->login to create a session";
		return 0;
	}

	if ( $uri =~ /\/REST\/Session/ ) {
		$$self{'message'} = "Please use the ->login, ->keepalive, or ->logout for managing sessions";
		return 0;
	}

	#catch internal use of session URI
	$uri = '/REST/Session/' if ( $uri eq 'OVERRIDESESSION' ); 

	#store URI and method for accessors
	$$self{'lasturi'} = $uri;
	$$self{'lastmethod'} = uc ( $method );

	#weak check for valid URI
	unless ( $uri =~ /^\/REST\// ) {
		$$self{'message'} = "Invalid REST URI.  Correctly formatted URIs start with '/REST/";
		return 0;
	}

	#Check for valid method type
	$method = uc( $method );
	unless ( $method eq 'GET' || $method eq 'POST' || $method eq 'PUT' || $method eq 'DELETE' ) {
		$$self{ 'message' } = 'Invalid method type.  Please use GET, PUT, POST, or DELETE.';
		return 0;
	}

	my $api_request = HTTP::Request->new( $method , "https://api.dynect.net$uri");
	$api_request->header ( 'Content-Type' => 'application/json' );
	$api_request->header ( 'Auth-Token' => $$self{'apitoken'} ) if ( defined $$self{'apitoken'} );
	$api_request->header ( 'Version' => $$self{'apiver'} ) if ( defined $$self{'apiver'} );
	if (defined $paramref) {
		$api_request->content( to_json( $paramref ) );
	}
	$api_request->header ( 'Content-Length' => length( $api_request->content ) )  if ( $method eq 'PUT' );
	my $api_result = $$self{'lwp'}->request( $api_request );
	$$self{'lastrc'} = $api_result->code;

	$$self{'resultref'} = decode_json ( $api_result->content ) if ( $api_result->is_success );
	until ( $api_result->is_success ) {
		#Fail out if we get an error code and the content is not in JSON format (weak test)
		if ( $api_result->is_error && ( substr( $api_result->content, 0, 1 ) ne '{' ) ) { 
			$$self{'message'} = "HTTPS Error: " . $api_result->status_line;
			$$self{'lasterrortype'} = 'HTTPS';
			return 0;
		}
		#on initial redirect the result->code is the URI to the Job ID
		#Calling the /REST/Job will return JSON in the content of status 
		elsif ( $api_result->is_redirect && ( substr( $api_result->content, 0, 1 ) ne '{' ) ) {
			sleep 1;
			$api_request = HTTP::Request->new('GET', "https://api.dynect.net" . $api_result->content);
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $$self{'apitoken'} );
			$api_request->header ( 'Version' => $$self{'apiver'} ) if ( defined $$self{'apiver'} );
			$api_result = $$self{'lwp'}->request( $api_request );
			$$self{'resultref'} = $api_result->code;
			redo;
		}
		else {
			#now safe to decode JSON
			$$self{'resultref'} = decode_json ( $api_result->content );

			#loop until the job id comes back as success or program dies
			if ( $$self{'resultref'}{'status'} ne 'success' ) {
				if ( $$self{'resultref'}{'status'} ne 'incomplete' ) {
					#api stauts != ( sucess || incomplete ) would indicate an API failure
					#Blank out stored message to do appends
					$$self{'message'} = '';
					$$self{'lasterrortype'} = 'API';
					foreach my $msgref ( @{$$self{'resultref'}{'msgs'}} ) {
						if ( length $$self{'message'} == 0 ) {
							#put in header is still blank
							$$self{'message'} .= "API Error:";
						}
						else {
							#put in double space if header already exists
							$$self{'message'} .= "\n";
						}
						$$self{'message'} .= "\n\tInfo: $msgref->{'INFO'}" if $msgref->{'INFO'};
						$$self{'message'} .= "\n\tLevel: $msgref->{'LVL'}" if $msgref->{'LVL'};
						$$self{'message'} .= "\n\tError Code: $msgref->{'ERR_CD'}" if $msgref->{'ERR_CD'};
						$$self{'message'} .= "\n\tSource: $msgref->{'SOURCE'}" if $msgref->{'SOURCE'};
					};
					$$self{'message'} .= "\n\nStopped ";
					return 0;
				}
				else {
					#status incomplete, wait 2 seconds and check again
					sleep 2;
					my $job_uri = "https://api.dynect.net/REST/Job/$$self{'resultref'}{'job_id'}/";
					$api_request = HTTP::Request->new('GET',$job_uri);
					$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $$self{'apitoken'} );
					$api_request->header ( 'Version' => $$self{'apiver'} ) if ( defined $$self{'apiver'} );
					$api_result = $$self{'lwp'}->request( $api_request );
					$$self{'lastrc'} = $api_result->code;
					redo;
				}
			}
		}
	}

	$$self{'message'} = "Request ( $uri, $method) successful";
	return 1;
}

sub version {
	my $self = shift;
	my $ver = shift;
	$$self{'apiver'} = $ver if ( defined $ver );
	return $$self{'apiver'};
}


sub message {
	my $self = shift; 
	return $$self{'message'};
}

#ALIAS TO RESULT
sub response {
	my $self = shift;
	return $self->result( @_ ) ; 
	}

sub result {
	my $self = shift;
	return $$self{'resultref'};
}

sub DESTROY {
	#call logout on destroy
	$_[0]->logout();
}

1;
