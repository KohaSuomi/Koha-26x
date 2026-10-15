use Modern::Perl;
use Koha::Installer::Output qw(say_success say_warning say_info);

return {
    bug_number  => "42770",
    description => "Add SIPoHTTP support: enable syspref and SIP account endpoint fields",
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

        # Add fields to sip_accounts table for SIPoHTTP endpoint configuration
        my $alter_check = $dbh->selectrow_array(
            q{SELECT COUNT(*) FROM information_schema.COLUMNS 
              WHERE TABLE_NAME='sip_accounts' AND COLUMN_NAME='sipohttp_host'}
        );

        unless ($alter_check) {
            $dbh->do(
                q{ALTER TABLE sip_accounts 
                  ADD COLUMN sipohttp_host VARCHAR(255) DEFAULT NULL COMMENT 'SIPoHTTP server host for this account',
                  ADD COLUMN sipohttp_port INT DEFAULT NULL COMMENT 'SIPoHTTP server port for this account'}
            );
        }

        say_success( $out, "Added new system preference 'SIPoHTTPEnabled'" );
        say_success( $out, "Added 'sip_accounts.sipohttp_host' and 'sip_accounts.sipohttp_port' columns" );
        say_info( $out, "SIPoHTTP REST API endpoint is now available at /api/v1/sipohttp" );
    },
};
