# RT-Extension-EmailHeader

#### Table of Contents

1. [About](#about)
2. [License](#license)
3. [Support](#support)
4. [Requirements](#requirements)
5. [Installation](#installation)
6. [Configuration](#configuration)

## About

Sets e.g. the Return-Path MIME header and adjusts the envelope's
Sender-Address so that bounces do not let RT create new tickets but to
update the originating ticket with a comment or reply.

## License

This project is licensed under the terms of the GNU General Public License Version 2.

This software is Copyright (c) 2018 by NETWAYS GmbH [support@netways.de](mailto:support@netways.de).

## Support

For bugs and feature requests please head over to our [issue tracker](https://github.com/NETWAYS/rt-extension-emailheader/issues).
You may also send us an email to [support@netways.de](mailto:support@netways.de) for general questions or to get technical support.

## Requirements

- RT 4.4.2

## Installation

Extract this extension to a temporary location.

Git clone:

    cd /usr/local/src
    git clone https://github.com/NETWAYS/rt-extension-emailheader

Tarball download:

    cd /usr/local/src
    wget https://github.com/NETWAYS/rt-extension-emailheader/archive/master.zip
    unzip master.zip

Navigate into the source directory and install the extension. (May need root permissions.)

    perl Makefile.PL
    make
    make install

Edit your `/opt/rt4/etc/RT_SiteConfig.pm`

Add this line:

    Plugin('RT::Extension::EmailHeader');

Clear your mason cache:

    rm -rf /opt/rt4/var/mason_data/obj

Restart your webserver.

## Configuration

You can change email headers and substitute them with ticket and/or
transaction attributes:

    Set($EmailHeader_AdditionalHeaders, {
        'Return-Path' => 'rt+__Ticket(id)__@my.rt.domain'
    });

    Set($EmailHeader_OverwriteSendmailArgs, '-f rt+__Ticket(id)__@my.rt.domain');

You can use the following markers:

    __Ticket__ (Ticket->Id);
    __Transaction__ (Transaction->Id);

    __Ticket(<attribute>)__
    __Transaction(<attribute>)__
