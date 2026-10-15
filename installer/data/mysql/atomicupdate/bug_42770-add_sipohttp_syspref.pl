use Modern::Perl;
use Koha::Installer::Output qw(say_success say_info);

return {
    bug_number  => "42770",
    description => "Add SIPoHTTP support: enable syspref for SIP message HTTP/XML forwarding",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        # Add syspref to enable/disable SIPoHTTP endpoint
        $dbh->do(
            q{
            INSERT IGNORE INTO systempreferences ( `variable`, `value`, `options`, `explanation`, `type` ) VALUES
            ('SIPoHTTPEnabled','0',NULL,'Enable the SIPoHTTP REST API endpoint (/api/v1/sipohttp) for forwarding SIP messages via HTTP/XML','YesNo');
	}
        );

        say_success( $out, "Added new system preference 'SIPoHTTPEnabled'" );
        say_info( $out, "SIPoHTTP REST API endpoint is now available at /api/v1/sipohttp (when enabled)" );
        say_info( $out, "SIPoHTTP listeners are configured in sipconfig.xml, same as the built-in SIP2 server" );
    },
};
