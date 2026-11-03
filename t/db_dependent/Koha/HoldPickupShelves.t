#!/usr/bin/perl

# Copyright 2026 Koha-Suomi Oy
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use Test::More;
use Test::Exception;

use t::lib::TestBuilder;
use t::lib::Mocks;

use Koha::Database;
use Koha::HoldPickupShelves;
use Koha::Libraries;
use Koha::Patrons;
use Koha::Patron::Categories;
use Koha::ItemTypes;
use Koha::Holds;
use C4::Context;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'search helpers' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $category = $builder->build_object( { class => 'Koha::Patron::Categories' } );
    my $itemtype = $builder->build_object( { class => 'Koha::ItemTypes' } );

    my $s1 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id         => $library->branchcode,
                priority           => 2,
                biblio_itemtype    => $itemtype->itemtype,
                patron_category_id => $category->categorycode,
                overflow_shelf     => 0,
                locked             => 0,
                max_items          => 5,
            }
        }
    );
    my $s2 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id      => $library->branchcode,
                priority        => 1,
                biblio_itemtype => $itemtype->itemtype,
                overflow_shelf  => 0,
                locked          => 0,
                max_items       => 5,
            }
        }
    );
    my $overflow = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id     => $library->branchcode,
                priority       => 9,
                overflow_shelf => 1,
                locked         => 0,
                max_items      => 5,
            }
        }
    );

    my $shelves = Koha::HoldPickupShelves->new;
    my @matched = $shelves->shelves_by_itemtype_and_category( $library->branchcode, $itemtype->itemtype, $category->categorycode );
    is( scalar(@matched), 1, 'shelves_by_itemtype_and_category returns one' );
    is( $matched[0]->hold_pickup_shelf_id, $s1->hold_pickup_shelf_id, 'correct shelf returned' );

    my @or = $shelves->shelves_by_itemtype_or_category( $library->branchcode, $itemtype->itemtype, 'NOMATCH' );
    is( scalar(@or), 2, 'shelves_by_itemtype_or_category returns matching shelves' );

    my @primary = $shelves->shelves_all_primary($library->branchcode);
    ok( scalar(@primary) >= 2, 'shelves_all_primary returns non-overflow shelves' );

    my @ov = $shelves->overflow_shelves($library->branchcode);
    is( scalar(@ov), 1, 'overflow_shelves returns overflow shelf' );

    $schema->storage->txn_rollback;
};

subtest 'available_shelves' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $biblio = $builder->build_sample_biblio();
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my $shelf1 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id         => $library->branchcode,
                shelf_name         => 'A10',
                max_items          => 5,
                overflow_shelf     => 0,
                locked             => 0,
                priority           => 1,
                weekday            => undef,
                biblio_itemtype    => undef,
                patron_category_id => undef,
                allow_multiple     => 0,
            }
        }
    );
    my $shelf2 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id         => $library->branchcode,
                shelf_name         => 'A2',
                max_items          => 5,
                overflow_shelf     => 0,
                locked             => 0,
                priority           => 2,
                weekday            => undef,
                biblio_itemtype    => undef,
                patron_category_id => undef,
                allow_multiple     => 0,
            }
        }
    );

    my $response = Koha::HoldPickupShelves->available_shelves( $library->branchcode, $biblio->biblionumber, $patron->borrowernumber );
    ok( ref($response) eq 'ARRAY', 'Response is array' );
    ok( scalar(@$response) >= 2, 'At least two shelves available' );
    is( $response->[0]->{shelf_name}, 'A10', 'First shelf sorted by priority' );
    ok( exists $response->[0]->{holds_count}, 'holds_count included' );

    # non-existent library
    my $none = Koha::HoldPickupShelves->available_shelves( 'NOPE', $biblio->biblionumber, $patron->borrowernumber );
    is( scalar(@$none), 0, 'No shelves for unknown library' );

    $schema->storage->txn_rollback;
};

subtest 'lock and open shelves' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $biblio = $builder->build_sample_biblio();
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my $old_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id     => $library->branchcode,
                locked         => 0,
                last_used_date => DateTime->now->subtract( days => 2 ),
                max_items      => 5,
            }
        }
    );
    my $dbh = $schema->storage->dbh;
    $dbh->do(
        q{ INSERT INTO reserves (biblionumber, borrowernumber, branchcode, hold_pickup_shelf_id) VALUES (?,?,?,?) },
        undef, $biblio->biblionumber, $patron->borrowernumber, $library->branchcode, $old_shelf->hold_pickup_shelf_id
    );

    my $shelves = Koha::HoldPickupShelves->new;
    $shelves->lock_previously_used_shelves($library->branchcode);
    is( Koha::HoldPickupShelves->find($old_shelf->hold_pickup_shelf_id)->locked, 1, 'Previously used shelf locked' );

    # empty locked shelf should be opened
    my $locked_empty = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id => $library->branchcode,
                locked     => 1,
                max_items  => 5,
            }
        }
    );
    $shelves->open_locked_shelves($library->branchcode);
    is( Koha::HoldPickupShelves->find($locked_empty->hold_pickup_shelf_id)->locked, 0, 'Empty locked shelf opened' );

    $schema->storage->txn_rollback;
};

subtest 'count and duplicate helpers' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $biblio = $builder->build_sample_biblio();
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my $shelf1 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, max_items => 5 }
        }
    );
    my $shelf2 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, max_items => 5 }
        }
    );

    my $dbh = $schema->storage->dbh;
    $dbh->do(
        q{ INSERT INTO reserves (biblionumber, borrowernumber, branchcode, hold_pickup_shelf_id) VALUES (?,?,?,?) },
        undef, $biblio->biblionumber, $patron->borrowernumber, $library->branchcode, $shelf1->hold_pickup_shelf_id
    );

    my $shelves = Koha::HoldPickupShelves->new;
    my %counts = $shelves->_get_holds_count_for_shelves( [ $shelf1->hold_pickup_shelf_id, $shelf2->hold_pickup_shelf_id ] );
    is( $counts{ $shelf1->hold_pickup_shelf_id }, 1, 'holds count for shelf1' );
    is( $counts{ $shelf2->hold_pickup_shelf_id }, undef, 'no count for empty shelf' );

    my %dup = $shelves->_check_duplicates_for_shelves( [ $shelf1->hold_pickup_shelf_id, $shelf2->hold_pickup_shelf_id ], $biblio->biblionumber );
    ok( $dup{ $shelf1->hold_pickup_shelf_id }, 'duplicate detected' );
    ok( !$dup{ $shelf2->hold_pickup_shelf_id }, 'no duplicate for empty shelf' );

    $schema->storage->txn_rollback;
};

subtest 'biblio_level_itemtypes' => sub {
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_preference( 'HoldPickupShelvesBiblioLevelItemTypeParameter', 'itemtypes' );

    my $response = Koha::HoldPickupShelves->biblio_level_itemtypes;
    ok( ref($response) eq 'ARRAY', 'Returns array' );
    if (@$response) {
        my @names = map { $_->{name} } @$response;
        my @sorted = sort { lc($a) cmp lc($b) } @names;
        is_deeply( \@names, \@sorted, 'Sorted case-insensitively' );
    }

    $schema->storage->txn_rollback;
};

done_testing();
