package Koha::REST::V1::SIPoHTTP;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

use C4::Auth qw(checkpw_internal);
use C4::Context;
use Koha::Exceptions;
use Koha::SIP2::Accounts;
use XML::LibXML;
use IO::Socket::INET;
use Socket qw(:crlf);
use Try::Tiny;
use Encode;
use File::Spec;

=head1 NAME

Koha::REST::V1::SIPoHTTP - REST controller for SIPoHTTP endpoint

=head1 API

=head2 POST /api/v1/sipohttp

Process SIP2 messages via HTTP/XML interface.

Request format:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ns1:sip xmlns:ns1="https://koha-suomi.fi/sipschema.xsd" 
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="https://koha-suomi.fi/sipschema.xsd"
         login="account_login_id" 
         password="account_password">
    <request>93USERNAME|PApassword|CI001|AO|</request>
</ns1:sip>
```

Response format:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ns1:sip xmlns:ns1="https://koha-suomi.fi/sipschema.xsd"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="https://koha-suomi.fi/sipschema.xsd">
    <response>98YYYYYN...</response>
</ns1:sip>
```

=cut

=head2 process

POST /api/v1/sipohttp

Process a SIP2 message forwarded via HTTP.

=cut

sub process {
    my $c = shift;

    # Check if SIPoHTTP is enabled
    unless ( C4::Context->preference('SIPoHTTPEnabled') ) {
        return $c->render(
            status => 404,
            openapi => { error => 'SIPoHTTP endpoint is not enabled' }
        );
    }

    my $body = $c->req->body || $c->param('query') || '';

    unless ($body) {
        return $c->render(
            status => 400,
            openapi => { error => 'Request body is empty' }
        );
    }

    # Parse XML request
    my ( $login, $password, $sip_message );
    try {
        my $parser = XML::LibXML->new();
        my $doc    = $parser->load_xml( string => $body );
        my $xc     = XML::LibXML::XPathContext->new( $doc->documentElement() );

        # Register namespace for XPath queries
        $xc->registerNs( 'ns1', 'https://koha-suomi.fi/sipschema.xsd' );

        # Extract attributes from root element
        my ($root) = $xc->findnodes('//ns1:sip');
        if ($root) {
            $login    = $root->getAttribute('login') or die 'Missing login attribute';
            $password = $root->getAttribute('password') or die 'Missing password attribute';
        } else {
            die 'Missing root sip element';
        }

        # Extract SIP message from request element (try with namespace, then without)
        my ($request_node) = $xc->findnodes('//ns1:request');
        $request_node = ($xc->findnodes('//request'))[0] unless $request_node;
        if ($request_node) {
            $sip_message = $request_node->textContent;
            $sip_message =~ s/\r//g;
            $sip_message =~ s/\n//g;
        } else {
            die 'Missing request element';
        }
    } catch {
        return $c->render(
            status => 400,
            openapi => { error => "Invalid XML: $_" }
        );
    };

    # Authenticate using SIP account credentials
    my $auth_ok = checkpw_internal( $login, $password );
    unless ($auth_ok) {
        return $c->render(
            status => 401,
            openapi => { error => 'Authentication failed' }
        );
    }

    # Look up SIP account by login_id
    my $sip_account = Koha::SIP2::Accounts->search( { login_id => $login } )->next;
    unless ($sip_account) {
        return $c->render(
            status => 404,
            openapi => { error => 'SIP account not found' }
        );
    }

    # Get SIP institution to look up listener in sipconfig.xml
    my $institution = $sip_account->sip_institution;
    unless ($institution) {
        return $c->render(
            status => 400,
            openapi => { error => 'SIP account does not have an associated institution' }
        );
    }

    # Load sipconfig.xml and find listener for this institution
    my ($sip_host, $sip_port);
    try {
        my $config_file = File::Spec->catfile( C4::Context->config('etcdir'), 'sipconfig.xml' );
        unless ( -f $config_file ) {
            die "sipconfig.xml not found at $config_file";
        }

        my $parser = XML::LibXML->new();
        my $doc = $parser->load_xml( location => $config_file );
        my $xc = XML::LibXML::XPathContext->new( $doc->documentElement() );

        # Register namespace if present
        $xc->registerNs( 'acs', 'http://openncip.org/acs-config/1.0/' );

        # Find listener for this institution
        my $institution_name = $institution->name;
        my $found_listener = 0;

        # Search for service elements that match the institution
        my @services = $xc->findnodes('//acs:acsconfig/acs:listeners/acs:service');
        foreach my $service (@services) {
            my $service_institution = $service->getAttribute('institution');
            if ( $service_institution && $service_institution eq $institution_name ) {
                # Extract host and port from service port attribute
                # Format: host:port/proto or similar
                my $port_attr = $service->getAttribute('port');
                if ( $port_attr =~ /^([^:]+):([0-9]+)/ ) {
                    $sip_host = $1;
                    $sip_port = $2;
                    $found_listener = 1;
                    last;
                }
            }
        }

        unless ($found_listener) {
            die "No listener found for institution '$institution_name' in sipconfig.xml";
        }
    } catch {
        return $c->render(
            status => 502,
            openapi => { error => "Cannot load SIP listener configuration: $_" }
        );
    }

    # Forward message to SIP server
    my $sip_response;
    try {
        my $socket = IO::Socket::INET->new(
            PeerAddr => $sip_host,
            PeerPort => $sip_port,
            Proto    => 'tcp'
        ) or die "Cannot connect to SIP server at $sip_host:$sip_port: $!";

        $socket->autoflush(1);
        my $terminator = $CRLF;
        $/ = $terminator;

        # Send SIP message
        print $socket $sip_message . $terminator;

        # Receive response
        $socket->recv( $sip_response, 8192 );

        $socket->shutdown(2);
        $socket->close();

        # Clean up response
        $sip_response =~ s/\r//g;
        $sip_response =~ s/\n//g;
    } catch {
        return $c->render(
            status => 502,
            openapi => { error => "SIP server communication error: $_" }
        );
    };

    # Build XML response
    my $xml_response = _build_xml_response($sip_response);

    return $c->render( 
        status       => 200, 
        text         => $xml_response,
        format       => 'xml'
    );
}

=head2 _build_xml_response

Build XML response from SIP message

=cut

sub _build_xml_response {
    my ($sip_message) = @_;

    my $doc  = XML::LibXML::Document->new( '1.0', 'utf-8' );
    my $root = $doc->createElement('ns1:sip');

    $root->setAttribute( 'xmlns:ns1' => 'https://koha-suomi.fi/sipschema.xsd' );
    $root->setAttribute( 'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance' );
    $root->setAttribute(
        'xsi:schemaLocation' => 'https://koha-suomi.fi/sipschema.xsd'
    );

    my $response = $doc->createElement('response');
    $response->appendTextNode($sip_message);
    $root->appendChild($response);

    $doc->setDocumentElement($root);

    return $doc->toString();
}

1;
