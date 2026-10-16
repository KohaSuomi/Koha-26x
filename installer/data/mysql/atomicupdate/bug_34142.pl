use Modern::Perl;
use Koha::Installer::Output qw(say_warning say_success say_info);

return {
    bug_number  => "34142",
    description => "Add column sublocation to (deleted)items table and new authorised value SUBLOC",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        if ( !column_exists( 'items', 'sublocation' ) ) {
            $dbh->do(q{ALTER TABLE items ADD COLUMN sublocation VARCHAR(80) DEFAULT NULL AFTER permanent_location});
            say_success( $out, "Added new column items.sublocation" );
        }
        if ( !column_exists( 'deleteditems', 'sublocation' ) ) {
            $dbh->do(
                q{ALTER TABLE deleteditems ADD COLUMN sublocation VARCHAR(80) DEFAULT NULL AFTER permanent_location});
            say_success( $out, "Added new column deleteditems.sublocation" );
        }

        $dbh->do(
            q{
            INSERT IGNORE INTO authorised_value_categories( category_name, is_system )
            VALUES ('SUBLOC', 0)
        }
        );
        say_success( $out, "Add SUBLOC category for authorised values" );
    },
};
