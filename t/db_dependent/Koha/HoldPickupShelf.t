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
use Koha::HoldPickupShelf;
use Koha::Libraries;
use Koha::Patrons;
use Koha::Patron::Categories;
use Koha::ItemTypes;
use Koha::Holds;
use C4::Context;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'basic CRUD and accessors' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $category = $builder->build_object( { class => 'Koha::Patron::Categories' } );

    my $shelf = Koha::HoldPickupShelf->new(
        {
            library_id         => $library->branchcode,
            shelf_name         => 'Test shelf',
            max_items          => 5,
            overflow_shelf     => 0,
            locked             => 0,
            priority           => 1,
            patron_category_id => $category->categorycode,
        }
    )->store;

    ok( $shelf->hold_pickup_shelf_id, 'Shelf stored with id' );
    is( $shelf->library->branchcode, $library->branchcode, 'library() returns related library' );
    is( $shelf->patron_category->categorycode, $category->categorycode, 'patron_category() returns related category' );

    $shelf->shelf_name('Updated shelf')->store;
    is( $shelf->shelf_name, 'Updated shelf', 'Shelf updated' );

    $schema->storage->txn_rollback;
};

subtest 'biblio_level_itemtype' => sub {
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_preference( 'HoldPickupShelvesBiblioLevelItemTypeParameter', 'itemtypes' );

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $itemtype = $builder->build_object( { class => 'Koha::ItemTypes' } );

    my $shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id     => $library->branchcode,
                biblio_itemtype => $itemtype->itemtype,
            }
        }
    );

    is( $shelf->biblio_level_itemtype, $itemtype->description, 'Returns item type description' );

    my $empty_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id     => $library->branchcode,
                biblio_itemtype => undef,
            }
        }
    );
    is( $empty_shelf->biblio_level_itemtype, '', 'Returns empty string when no item type' );

    $schema->storage->txn_rollback;
};

subtest 'available_shelf' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $patron_category = $builder->build_object( { class => 'Koha::Patron::Categories' } );
    my $biblio = $builder->build_sample_biblio();
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my @days = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
    my $today = $days[(localtime)[6]];
    my $other_day = $days[ ( (localtime)[6] + 1 ) % 7 ];

    my $shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id         => $library->branchcode,
                max_items          => 5,
                locked             => 0,
                overflow_shelf     => 0,
                weekday            => undef,
                biblio_itemtype    => undef,
                patron_category_id => undef,
                allow_multiple     => 0,
            }
        }
    );
    ok( $shelf->available_shelf($biblio, $patron), 'Available with no constraints' );

    my $cat_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id         => $library->branchcode,
                max_items          => 5,
                patron_category_id => $patron_category->categorycode,
                weekday            => undef,
                biblio_itemtype    => undef,
                allow_multiple     => 0,
            }
        }
    );
    ok( !$cat_shelf->available_shelf($biblio, $patron), 'Unavailable when patron category mismatches' );

    my $itype_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id      => $library->branchcode,
                max_items       => 5,
                biblio_itemtype => 'NOTEXIST',
                weekday         => undef,
                allow_multiple  => 0,
            }
        }
    );
    ok( !$itype_shelf->available_shelf($biblio, $patron), 'Unavailable when biblio itemtype mismatches' );

    my $full_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id => $library->branchcode,
                max_items  => 0,
                weekday    => undef,
                allow_multiple => 0,
            }
        }
    );
    ok( !$full_shelf->available_shelf($biblio, $patron), 'Unavailable when max_items reached' );

    my $weekday_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id => $library->branchcode,
                max_items          => 5,
                weekday            => $other_day,
                biblio_itemtype    => undef,
                patron_category_id => undef,
                allow_multiple     => 0,
            }
        }
    );
    ok( !$weekday_shelf->available_shelf($biblio, $patron), 'Unavailable on wrong weekday' );

    my $today_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id => $library->branchcode,
                max_items          => 5,
                weekday            => $today,
                biblio_itemtype    => undef,
                patron_category_id => undef,
                allow_multiple     => 0,
            }
        }
    );
    ok( $today_shelf->available_shelf($biblio, $patron), 'Available on matching weekday' );

    $schema->storage->txn_rollback;
};

subtest 'duplicate_shelf and duplicate_record' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $biblio = $builder->build_sample_biblio();
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my $shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id => $library->branchcode,
                shelf_name => 'Dup shelf',
                max_items  => 5,
                weekday    => undef,
                allow_multiple => 0,
            }
        }
    );

    is( $shelf->duplicate_shelf, $shelf->hold_pickup_shelf_id, 'duplicate_shelf returns own id for existing shelf' );

    my $duplicate = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => {
                library_id         => $library->branchcode,
                shelf_name         => 'Dup shelf',
                max_items          => 5,
                weekday            => undef,
                biblio_itemtype    => $shelf->biblio_itemtype,
                patron_category_id => $shelf->patron_category_id,
                allow_multiple     => 0,
            }
        }
    );
    is( $duplicate->duplicate_shelf, $shelf->hold_pickup_shelf_id, 'duplicate_shelf returns existing id' );

    is( $shelf->duplicate_record($biblio->biblionumber), 0, 'No duplicate record initially' );

    my $dbh = $schema->storage->dbh;
    $dbh->do(
        q{ INSERT INTO reserves (biblionumber, borrowernumber, branchcode, hold_pickup_shelf_id) VALUES (?,?,?,?) },
        undef, $biblio->biblionumber, $patron->borrowernumber, $library->branchcode, $shelf->hold_pickup_shelf_id
    );

    is( $shelf->duplicate_record($biblio->biblionumber), 1, 'duplicate_record detects existing hold' );

    $shelf->allow_multiple(1)->store;
    is( $shelf->duplicate_record($biblio->biblionumber), 0, 'allow_multiple bypasses duplicate_record' );

    $schema->storage->txn_rollback;
};

subtest 'priority calculation' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );

    my $shelf1 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, priority => 1, max_items => 5 }
        }
    );
    my $shelf2 = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, priority => 2, max_items => 5 }
        }
    );

    my $before_priority = (Koha::HoldPickupShelves->search( {}, { order_by => { -asc => 'priority' } } )->last
        ? Koha::HoldPickupShelves->search( {}, { order_by => { -asc => 'priority' } } )->last->priority
        : 0);

    my $shelf3 = Koha::HoldPickupShelf->new( { library_id => $library->branchcode, shelf_name => 'P', max_items => 5 } );
    my $expected_priority = $before_priority + 1;
    is( $shelf3->calculate_priority(), $expected_priority, 'calculate_priority assigns next priority' );
    $shelf3->store;

    is( $shelf3->calculate_priority(1), 1, 'calculate_priority accepts explicit priority' );
    is( $shelf3->priority, 1, 'shelf priority set to explicit value' );

    $schema->storage->txn_rollback;
};

subtest 'holds_count and set_last_used_date' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $biblio = $builder->build_sample_biblio();
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my $shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, max_items => 5 }
        }
    );

    is( $shelf->holds_count, 0, 'holds_count is 0 initially' );

    my $dbh = $schema->storage->dbh;
    $dbh->do(
        q{ INSERT INTO reserves (biblionumber, borrowernumber, branchcode, hold_pickup_shelf_id) VALUES (?,?,?,?) },
        undef, $biblio->biblionumber, $patron->borrowernumber, $library->branchcode, $shelf->hold_pickup_shelf_id
    );

    is( $shelf->holds_count, 1, 'holds_count updated after insert' );

    $shelf->set_last_used_date;
    ok( $shelf->last_used_date, 'last_used_date set' );

    $schema->storage->txn_rollback;
};

subtest 'lock_full_shelf and delete' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $biblio = $builder->build_sample_biblio();
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my $shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, max_items => 1 }
        }
    );

    my $dbh = $schema->storage->dbh;
    $dbh->do(
        q{ INSERT INTO reserves (biblionumber, borrowernumber, branchcode, hold_pickup_shelf_id) VALUES (?,?,?,?) },
        undef, $biblio->biblionumber, $patron->borrowernumber, $library->branchcode, $shelf->hold_pickup_shelf_id
    );

    $shelf->lock_full_shelf;
    is( Koha::HoldPickupShelves->find($shelf->hold_pickup_shelf_id)->locked, 1, 'Shelf locked when full' );

    throws_ok { $shelf->delete } 'Koha::Exceptions::Object::FKConstraint', 'delete throws when holds exist';

    my $empty_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, max_items => 5 }
        }
    );
    lives_ok { $empty_shelf->delete } 'Empty shelf deleted';

    $schema->storage->txn_rollback;
};

subtest 'weekday_match' => sub {
    $schema->storage->txn_begin;

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my @days = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
    my $today = $days[(localtime)[6]];
    my $other_day = $days[ ( (localtime)[6] + 1 ) % 7 ];

    my $today_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, weekday => $today, max_items => 5 }
        }
    );
    ok( $today_shelf->weekday_match, 'weekday_match true for today' );

    my $other_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, weekday => $other_day, max_items => 5 }
        }
    );
    ok( !$other_shelf->weekday_match, 'weekday_match false for other day' );

    my $any_shelf = $builder->build_object(
        {
            class => 'Koha::HoldPickupShelves',
            value => { library_id => $library->branchcode, weekday => undef, max_items => 5 }
        }
    );
    ok( $any_shelf->weekday_match, 'weekday_match true when no weekday set' );

    $schema->storage->txn_rollback;
};

done_testing();
