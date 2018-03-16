package RT::Extension::EmailHeader;

use 5.010_001;
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

RT-Extension-EmailHeader

=head1 DESCRIPTION

Sets e.g. the C<Return-Path> MIME header and adjusts the envelope's C<Sender-Address> so that bounces
do not let RT create new tickets but to update the originating ticket with a comment or reply.

=head1 RT VERSION

Works with RT 4.2

=head1 INSTALLATION

=over

=item C<perl Makefile.PL>

=item C<make>

=item C<make install>

May need root permissions

=item Edit your F</opt/rt4/etc/RT_SiteConfig.pm>

Add this line:

    Plugin('RT::Extension::EmailHeader');

=item Clear your mason cache

    rm -rf /opt/rt4/var/mason_data/obj

=item Restart your webserver

=back

=head1 CONFIGURATION

You can change email headers and substitute them with ticket and/or transaction attributes:

    Set($EmailHeader_AdditionalHeaders, {
        'Return-Path' => 'rt+__Ticket(id)__@my.rt.domain'
    });

    Set($EmailHeader_OverwriteSendmailArgs, '-f rt+__Ticket(id)__@my.rt.domain');

You can use the following markers:

    __Ticket__ (Ticket->Id);
    __Transaction__ (Transaction->Id);

    __Ticket(<attribute>)__
    __Transaction(<attribute>)__

=head1 AUTHOR

NETWAYS GmbH <lt>support@netways.de<gt>

=head1 BUGS

All bugs should be reported on L<GitHub|https://github.com/NETWAYS/rt-extension-emailheader>.

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2018 by NETWAYS GmbH

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

__END__
