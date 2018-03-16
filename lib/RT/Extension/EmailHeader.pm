package RT::Extension::EmailHeader;

use strict;

use version;

our $VERSION="1.0.0";

use Hook::LexWrap;
use RT::Interface::Email;

sub rewriteString {
        my $string = shift;
        my $ticket = shift;
        my $transaction = shift;

        if (ref($ticket) eq 'RT::Ticket') {
                $string =~ s/__Ticket__/$ticket->Id/ge;
                $string =~ s/__Ticket\(([^\)]+)\)__/$ticket->$1/ge;
        } else {
                $string =~ s/__Ticket__/0/g;
                $string =~ s/__Ticket\(([^\)]+)\)__/0/g;
        }

        if (ref($transaction) eq 'RT::Transaction') {
                $string =~ s/__Transaction__/$transaction->Id/ge;
                $string =~ s/__Transaction\(([^\)]+)\)__/$transaction->$1/ge;
        } else {
                $string =~ s/__Transaction__/0/g;
                $string =~ s/__Transaction\(([^\)]+)\)__/0/g;
        }

        return $string;
}

wrap *RT::Interface::Email::SendEmail,
	'pre' => sub {

		my $length = scalar(@_);

		$length-- if ($length %2 ne 0);

		my @a = splice(@_, 0, $length);

		my (%args) = (
	        Entity => undef,
	        Bounce => 0,
	        Ticket => undef,
	        Transaction => undef,
	        @a
	    );

		if ($args{'Ticket'} && $args{'Ticket'}->Id) {
			my $header = RT->Config->Get('EmailHeader_AdditionalHeaders') || {};
			while(my($header,$value) = each(%{ $header })) {

				$value = rewriteString($value, $args{'Ticket'}, $args{'Transaction'});

				RT->Logger->info("Adding header: $header: $value");

				$args{'Entity'}->head->set($header, $value);
			}
		}

	    my @newargs = %args;
	    $newargs[-1] = $_[-1];
	    @_ = @newargs;
	};

1;
=pod

=head1 NAME

RT::Extension::EmailHeader

=head1 VERSION

version 1.0.0

=head1 AUTHOR

Marius Hein <marius.hein@netways.de>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by NETWAYS GmbH <info@netways.de>

This is free software, licensed under:
    GPL Version 2, June 1991

=cut

__END__
