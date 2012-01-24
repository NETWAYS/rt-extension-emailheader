package RTx::EmailHeader;

use strict;
use version "1.0";
use Hook::LexWrap;
use RT::Interface::Email;


wrap *RT::Interface::Email::SendEmail,
	'pre' => sub {
		RT->Logger->error("LAOLA");
		my @a = splice(@_, 0);
		my (%args) = (
	        Entity => undef,
	        Bounce => 0,
	        Ticket => undef,
	        Transaction => undef,
	        @a
	    );
	    
		if ($args{'Ticket'} && $args{'Ticket'}->Id) {
			my $header = RT->Config->Get('RTx_EmailHeader_AdditionalHeaders') || {};
			while(my($header,$value) = each(%{ $header })) {
				
				$value =~ s/__Ticket__/$args{'Ticket'}->Id/ge;
				$value =~ s/__Ticket\(([^\)]+)\)__/$args{'Ticket'}->$1/ge;
				
				$value =~ s/__Transaction__/$args{'Transaction'}->Id/ge;
				$value =~ s/__Transaction\(([^\)]+)\)__/$args{'Transaction'}->$1/ge;
				
				RT->Logger->info("Adding header: $header: $value");
				
				$args{'Entity'}->head->set($header, $value);
			}
		}
	    
	    my @newargs = %args;
	    $newargs[-1] = $_[-1];
	    @_ = @newargs;
	};

1;




