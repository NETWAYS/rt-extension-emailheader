use strict;
no warnings qw(redefine);
package RT::Interface::Email;

sub SendEmail {
    my (%args) = (
        Entity => undef,
        Bounce => 0,
        Ticket => undef,
        Transaction => undef,
        @_,
    );

    my $TicketObj = $args{'Ticket'};
    my $TransactionObj = $args{'Transaction'};

    foreach my $arg( qw(Entity Bounce) ) {
        next unless defined $args{ lc $arg };

        $RT::Logger->warning("'". lc($arg) ."' argument is deprecated, use '$arg' instead");
        $args{ $arg } = delete $args{ lc $arg };
    }

    unless ( $args{'Entity'} ) {
        $RT::Logger->crit( "Could not send mail without 'Entity' object" );
        return 0;
    }

    my $msgid = $args{'Entity'}->head->get('Message-ID') || '';
    chomp $msgid;
    
    # If we don't have any recipients to send to, don't send a message;
    unless ( $args{'Entity'}->head->get('To')
        || $args{'Entity'}->head->get('Cc')
        || $args{'Entity'}->head->get('Bcc') )
    {
        $RT::Logger->info( $msgid . " No recipients found. Not sending." );
        return -1;
    }

    if ($args{'Entity'}->head->get('X-RT-Squelch')) {
        $RT::Logger->info( $msgid . " Squelch header found. Not sending." );
        return -1;
    }

    if ( $TransactionObj && !$TicketObj
        && $TransactionObj->ObjectType eq 'RT::Ticket' )
    {
        $TicketObj = $TransactionObj->Object;
    }

    if ( RT->Config->Get('GnuPG')->{'Enable'} ) {
        my %crypt;

        my $attachment;
        $attachment = $TransactionObj->Attachments->First
            if $TransactionObj;

        foreach my $argument ( qw(Sign Encrypt) ) {
            next if defined $args{ $argument };

            if ( $attachment && defined $attachment->GetHeader("X-RT-$argument") ) {
                $crypt{$argument} = $attachment->GetHeader("X-RT-$argument");
            } elsif ( $TicketObj ) {
                $crypt{$argument} = $TicketObj->QueueObj->$argument();
            }
        }

        my $res = SignEncrypt( %args, %crypt );
        return $res unless $res > 0;
    }

    unless ( $args{'Entity'}->head->get('Date') ) {
        require RT::Date;
        my $date = RT::Date->new( RT->SystemUser );
        $date->SetToNow;
        $args{'Entity'}->head->set( 'Date', $date->RFC2822( Timezone => 'server' ) );
    }

    my $mail_command = RT->Config->Get('MailCommand');
    
	# RTx::EmailHeader MOD
	my $sendmailAdd = undef;
    if (RT->Config->Get('RTx_EmailHeader_OverwriteSendmailArgs')) {
    	$sendmailAdd = RT->Config->Get('RTx_EmailHeader_OverwriteSendmailArgs');
        $sendmailAdd = RTx::EmailHeader::rewriteString($sendmailAdd, $TicketObj, $TransactionObj);
        RT->Logger->info("Adding custom sendmail args: $sendmailAdd");
	}
    

    if ($mail_command eq 'testfile' and not $Mail::Mailer::testfile::config{outfile}) {
        $Mail::Mailer::testfile::config{outfile} = File::Temp->new;
        $RT::Logger->info("Storing outgoing emails in $Mail::Mailer::testfile::config{outfile}");
    }

    # if it is a sub routine, we just return it;
    return $mail_command->($args{'Entity'}) if UNIVERSAL::isa( $mail_command, 'CODE' );

    if ( $mail_command eq 'sendmailpipe' ) {
        my $path = RT->Config->Get('SendmailPath');
        my $args = RT->Config->Get('SendmailArguments');

        # SetOutgoingMailFrom
        if ( RT->Config->Get('SetOutgoingMailFrom') ) {
            my $OutgoingMailAddress;

            if ($TicketObj) {
                my $QueueName = $TicketObj->QueueObj->Name;
                my $QueueAddressOverride = RT->Config->Get('OverrideOutgoingMailFrom')->{$QueueName};

                if ($QueueAddressOverride) {
                    $OutgoingMailAddress = $QueueAddressOverride;
                } else {
                    $OutgoingMailAddress = $TicketObj->QueueObj->CorrespondAddress;
                }
            }

            $OutgoingMailAddress ||= RT->Config->Get('OverrideOutgoingMailFrom')->{'Default'};

            $args .= " -f $OutgoingMailAddress"
                if $OutgoingMailAddress;            
        }

        # Set Bounce Arguments
        $args .= ' '. RT->Config->Get('SendmailBounceArguments') if $args{'Bounce'};

        # VERP
        if ( $TransactionObj and
             my $prefix = RT->Config->Get('VERPPrefix') and
             my $domain = RT->Config->Get('VERPDomain') )
        {
            my $from = $TransactionObj->CreatorObj->EmailAddress;
            $from =~ s/@/=/g;
            $from =~ s/\s//g;
            $args .= " -f $prefix$from\@$domain";
        }
        
        $args .= " $sendmailAdd" if ($sendmailAdd);

        eval {
            # don't ignore CHLD signal to get proper exit code
            local $SIG{'CHLD'} = 'DEFAULT';

            open( my $mail, '|-', "$path $args >/dev/null" )
                or die "couldn't execute program: $!";

            # if something wrong with $mail->print we will get PIPE signal, handle it
            local $SIG{'PIPE'} = sub { die "program unexpectedly closed pipe" };
            $args{'Entity'}->print($mail);

            unless ( close $mail ) {
                die "close pipe failed: $!" if $!; # system error
                # sendmail exit statuses mostly errors with data not software
                # TODO: status parsing: core dump, exit on signal or EX_*
                my $msg = "$msgid: `$path $args` exitted with code ". ($?>>8);
                $msg = ", interrupted by signal ". ($?&127) if $?&127;
                $RT::Logger->error( $msg );
                die $msg;
            }
        };
        if ( $@ ) {
            $RT::Logger->crit( "$msgid: Could not send mail with command `$path $args`: " . $@ );
            if ( $TicketObj ) {
                _RecordSendEmailFailure( $TicketObj );
            }
            return 0;
        }
    }
    elsif ( $mail_command eq 'smtp' ) {
        require Net::SMTP;
        my $smtp = do { local $@; eval { Net::SMTP->new(
            Host  => RT->Config->Get('SMTPServer'),
            Debug => RT->Config->Get('SMTPDebug'),
        ) } };
        unless ( $smtp ) {
            $RT::Logger->crit( "Could not connect to SMTP server.");
            if ($TicketObj) {
                _RecordSendEmailFailure( $TicketObj );
            }
            return 0;
        }

        # duplicate head as we want drop Bcc field
        my $head = $args{'Entity'}->head->dup;
        my @recipients = map $_->address, map 
            Email::Address->parse($head->get($_)), qw(To Cc Bcc);                       
        $head->delete('Bcc');

        my $sender = RT->Config->Get('SMTPFrom')
            || $args{'Entity'}->head->get('From');
        chomp $sender;

        my $status = $smtp->mail( $sender )
            && $smtp->recipient( @recipients );

        if ( $status ) {
            $smtp->data;
            my $fh = $smtp->tied_fh;
            $head->print( $fh );
            print $fh "\n";
            $args{'Entity'}->print_body( $fh );
            $smtp->dataend;
        }
        $smtp->quit;

        unless ( $status ) {
            $RT::Logger->crit( "$msgid: Could not send mail via SMTP." );
            if ( $TicketObj ) {
                _RecordSendEmailFailure( $TicketObj );
            }
            return 0;
        }
    }
    else {
        local ($ENV{'MAILADDRESS'}, $ENV{'PERL_MAILERS'});

        my @mailer_args = ($mail_command);
        if ( $mail_command eq 'sendmail' ) {
            $ENV{'PERL_MAILERS'} = RT->Config->Get('SendmailPath');
            push @mailer_args, split(/\s+/, RT->Config->Get('SendmailArguments'));
        }
        else {
            push @mailer_args, RT->Config->Get('MailParams');
        }

        unless ( $args{'Entity'}->send( @mailer_args ) ) {
            $RT::Logger->crit( "$msgid: Could not send mail." );
            if ( $TicketObj ) {
                _RecordSendEmailFailure( $TicketObj );
            }
            return 0;
        }
    }
    return 1;
}


1;
