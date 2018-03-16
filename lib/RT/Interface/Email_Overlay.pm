use strict;
no warnings qw(redefine);
package RT::Interface::Email;

our $logfile;

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

    unless ( $args{'Entity'} ) {
        $RT::Logger->crit( "Could not send mail without 'Entity' object" );
        return 0;
    }

    my $msgid = Encode::decode( "UTF-8", $args{'Entity'}->head->get('Message-ID') || '' );
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

    if (my $precedence = RT->Config->Get('DefaultMailPrecedence')
        and !$args{'Entity'}->head->get("Precedence")
    ) {
        if ($TicketObj) {
            my $Overrides = RT->Config->Get('OverrideMailPrecedence') || {};
            my $Queue = $TicketObj->QueueObj;

            $precedence = $Overrides->{$Queue->id}
                if exists $Overrides->{$Queue->id};
            $precedence = $Overrides->{$Queue->Name}
                if exists $Overrides->{$Queue->Name};
        }

        $args{'Entity'}->head->replace( 'Precedence', Encode::encode("UTF-8",$precedence) )
            if $precedence;
    }

    if ( $TransactionObj && !$TicketObj
        && $TransactionObj->ObjectType eq 'RT::Ticket' )
    {
        $TicketObj = $TransactionObj->Object;
    }

    my $head = $args{'Entity'}->head;
    unless ( $head->get('Date') ) {
        require RT::Date;
        my $date = RT::Date->new( RT->SystemUser );
        $date->SetToNow;
        $head->replace( 'Date', Encode::encode("UTF-8",$date->RFC2822( Timezone => 'server' ) ) );
    }
    unless ( $head->get('MIME-Version') ) {
        # We should never have to set the MIME-Version header
        $head->replace( 'MIME-Version', '1.0' );
    }
    unless ( $head->get('Content-Transfer-Encoding') ) {
        # fsck.com #5959: Since RT sends 8bit mail, we should say so.
        $head->replace( 'Content-Transfer-Encoding', '8bit' );
    }

    if ( RT->Config->Get('Crypt')->{'Enable'} ) {
        %args = WillSignEncrypt(
            %args,
            Attachment => $TransactionObj ? $TransactionObj->Attachments->First : undef,
            Ticket     => $TicketObj,
        );
        my $res = SignEncrypt( %args );
        return $res unless $res > 0;
    }

    my $mail_command = RT->Config->Get('MailCommand');

    # RT::Extension::EmailHeader MOD
    my $sendmailAdd = undef;
    if (RT->Config->Get('EmailHeader_OverwriteSendmailArgs')) {
        $sendmailAdd = RT->Config->Get('EmailHeader_OverwriteSendmailArgs');
        $sendmailAdd = RT::Extension::EmailHeader::rewriteString($sendmailAdd, $TicketObj, $TransactionObj);
        RT->Logger->info("Adding custom sendmail args: $sendmailAdd");
    }

    # if it is a sub routine, we just return it;
    return $mail_command->($args{'Entity'}) if UNIVERSAL::isa( $mail_command, 'CODE' );

    if ( $mail_command eq 'sendmailpipe' ) {
        my $path = RT->Config->Get('SendmailPath');
        my @args = shellwords(RT->Config->Get('SendmailArguments'));
        push @args, "-t" unless grep {$_ eq "-t"} @args;
        push @args, $sendmailAdd if ($sendmailAdd);  # RT::Extension::EmailHeader MOD

        # SetOutgoingMailFrom and bounces conflict, since they both want -f
        if ( $args{'Bounce'} ) {
            push @args, shellwords(RT->Config->Get('SendmailBounceArguments'));
        } elsif ( RT->Config->Get('SetOutgoingMailFrom') ) {
            my $OutgoingMailAddress = _OutgoingMailFrom($TicketObj);

            push @args, "-f", $OutgoingMailAddress
                if $OutgoingMailAddress;
        }

        # VERP
        if ( $TransactionObj and
             my $prefix = RT->Config->Get('VERPPrefix') and
             my $domain = RT->Config->Get('VERPDomain') )
        {
            my $from = $TransactionObj->CreatorObj->EmailAddress;
            $from =~ s/@/=/g;
            $from =~ s/\s//g;
            push @args, "-f", "$prefix$from\@$domain";
        }

        eval {
            # don't ignore CHLD signal to get proper exit code
            local $SIG{'CHLD'} = 'DEFAULT';

            # if something wrong with $mail->print we will get PIPE signal, handle it
            local $SIG{'PIPE'} = sub { die "program unexpectedly closed pipe" };

            require IPC::Open2;
            my ($mail, $stdout);
            my $pid = IPC::Open2::open2( $stdout, $mail, $path, @args )
                or die "couldn't execute program: $!";

            $args{'Entity'}->print($mail);
            close $mail or die "close pipe failed: $!";

            waitpid($pid, 0);
            if ($?) {
                # sendmail exit statuses mostly errors with data not software
                # TODO: status parsing: core dump, exit on signal or EX_*
                my $msg = "$msgid: `$path @args` exited with code ". ($?>>8);
                $msg = ", interrupted by signal ". ($?&127) if $?&127;
                $RT::Logger->error( $msg );
                die $msg;
            }
        };
        if ( $@ ) {
            $RT::Logger->crit( "$msgid: Could not send mail with command `$path @args`: " . $@ );
            if ( $TicketObj ) {
                _RecordSendEmailFailure( $TicketObj );
            }
            return 0;
        }
    } elsif ( $mail_command eq 'mbox' ) {
        my $now = RT::Date->new(RT->SystemUser);
        $now->SetToNow;

        state $logfile;
        unless ($logfile) {
            my $when = $now->ISO( Timezone => "server" );
            $when =~ s/\s+/-/g;
            $logfile = "$RT::VarPath/$when.mbox";
            $RT::Logger->info("Storing outgoing emails in $logfile");
        }
        my $fh;
        unless (open($fh, ">>", $logfile)) {
            $RT::Logger->crit( "Can't open mbox file $logfile: $!" );
            return 0;
        }
        my $content = $args{Entity}->stringify;
        $content =~ s/^(>*From )/>$1/mg;
        my $user = $ENV{USER} || getpwuid($<);
        print $fh "From $user\@localhost  ".localtime()."\n";
        print $fh $content, "\n";
        close $fh;
    } else {
        local ($ENV{'MAILADDRESS'}, $ENV{'PERL_MAILERS'});

        my @mailer_args = ($mail_command);
        if ( $mail_command eq 'sendmail' ) {
            $ENV{'PERL_MAILERS'} = RT->Config->Get('SendmailPath');
            push @mailer_args, grep {$_ ne "-t"}
                split(/\s+/, RT->Config->Get('SendmailArguments'));
        } elsif ( $mail_command eq 'testfile' ) {
            unless ($Mail::Mailer::testfile::config{outfile}) {
                $Mail::Mailer::testfile::config{outfile} = File::Temp->new;
                $RT::Logger->info("Storing outgoing emails in $Mail::Mailer::testfile::config{outfile}");
            }
        } else {
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
