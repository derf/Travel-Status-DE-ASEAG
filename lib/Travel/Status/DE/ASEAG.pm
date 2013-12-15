package Travel::Status::DE::ASEAG;

use strict;
use warnings;
use 5.010;

no if $] >= 5.018, warnings => "experimental::smartmatch";

our $VERSION = '0.00';

use Carp qw(confess cluck);
use DateTime;
use Encode qw(encode decode);
use List::MoreUtils qw(none);
use LWP::UserAgent;
use Travel::Status::DE::ASEAG::Result;

sub new {
	my ( $class, %opt ) = @_;

	my $ua = LWP::UserAgent->new(%opt);

	my $self = {
		full_routes => $opt{full_routes} // 0,
		fuzzy       => $opt{fuzzy}       // 1,
		hide_past   => $opt{hide_past}   // 1,
		stop        => $opt{stop},
		via         => $opt{via},
		post        => {
			ReturnList =>
			  'lineid,linename,directionid,destinationtext,vehicleid,'
			  . 'tripid,estimatedtime,stopid,stoppointname'
		},
	};

	bless( $self, $class );

	$ua->env_proxy;

	my $response = $ua->post( 'http://ivu.aseag.de/interfaces/ura/instant_V1',
		$self->{post} );

	if ( $response->is_error ) {
		$self->{errstr} = $response->status_line;
		return $self;
	}

	$self->{raw_str} = $response->decoded_content;

	for my $dep ( split( /\r\n/, $self->{raw_str} ) ) {
		$dep =~ s{^\[}{};
		$dep =~ s{\]$}{};

		# first field == 4 => version information, no departure
		if ( substr( $dep, 0, 1 ) != 4 ) {
			push( @{ $self->{raw_list} }, [ split( /"?,"?/, $dep ) ] );
		}
	}

	return $self;
}

sub new_from_raw {
	my ( $class, %opt ) = @_;

	my $self = { raw_str => $opt{raw_str}, };

	for my $dep ( split( /\r\n/, $self->{raw} ) ) {
		$dep =~ s{^\[}{};
		$dep =~ s{\]$}{};

		# first field == 4 => version information, no departure
		if ( substr( $dep, 0, 1 ) != 4 ) {
			push( @{ $self->{raw_list} }, [ split( /"?,"?/, $dep ) ] );
		}
	}

	return bless( $self, $class );
}

sub errstr {
	my ($self) = @_;

	return $self->{errstr};
}

sub sprintf_date {
	my ($e) = @_;

	return sprintf( '%02d.%02d.%d',
		$e->getAttribute('day'),
		$e->getAttribute('month'),
		$e->getAttribute('year'),
	);
}

sub sprintf_time {
	my ($e) = @_;

	return sprintf( '%02d:%02d',
		$e->getAttribute('hour'),
		$e->getAttribute('minute'),
	);
}

sub is_my_stop {
	my ( $self, $stop, $my_stop, $fuzzy ) = @_;

	if ($fuzzy) {
		return ( $stop =~ m{ $my_stop }ix ? 1 : 0 );
	}
	else {
		return ( $stop eq $my_stop );
	}
}

sub results {
	my ( $self, %opt ) = @_;
	my @results;

	my $full_routes = $opt{full_routes} // $self->{full_routes} // 0;
	my $fuzzy       = $opt{fuzzy}       // $self->{fuzzy}       // 1;
	my $hide_past   = $opt{hide_past}   // $self->{hide_past}   // 1;
	my $stop        = $opt{stop}        // $self->{stop};
	my $via         = $opt{via}         // $self->{via};

	my $dt_now = DateTime->now( time_zone => 'Europe/Berlin' );
	my $ts_now = $dt_now->epoch;

	if ($via) {
		$full_routes ||= 'after';
	}

	for my $dep ( @{ $self->{raw_list} } ) {

		my (
			$u1, $stopname, $stopid,    $lineid, $linename,
			$u2, $dest,     $vehicleid, $tripid, $timestamp
		) = @{$dep};
		my @route;

		if ( $stop and not $self->is_my_stop( $stopname, $stop, $fuzzy ) ) {
			next;
		}

		if ( not $timestamp ) {
			cluck("departure element without timestamp: $dep");
			next;
		}

		my $dt_dep = DateTime->from_epoch(
			epoch     => $timestamp / 1000,
			time_zone => 'Europe/Berlin'
		);
		my $ts_dep = $dt_dep->epoch;

		if ( $hide_past and $dt_dep->subtract_datetime($dt_now)->is_negative ) {
			next;
		}

		if ($full_routes) {
			@route = map { [ $_->[9] / 1000, $_->[1] ] }
			  grep { $_->[8] == $tripid } @{ $self->{raw_list} };

			if ( $full_routes eq 'before' ) {
				@route = grep { $_->[0] < $ts_dep } @route;
			}
			elsif ( $full_routes eq 'after' ) {
				@route = grep { $_->[0] > $ts_dep } @route;
			}

			if ( $via
				and none { $self->is_my_stop( $_->[1], $via, $fuzzy ) } @route )
			{
				next;
			}

			if ($hide_past) {
				@route = grep { $_->[0] >= $ts_now } @route;
			}

			@route = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map { [ $_, $_->[0] ] } @route;

			@route = map {
				[
					DateTime->from_epoch(
						epoch     => $_->[0],
						time_zone => 'Europe/Berlin'
					),
					decode( 'UTF-8', $_->[1] )
				]
			} @route;
		}

		push(
			@results,
			Travel::Status::DE::ASEAG::Result->new(
				date        => $dt_dep->strftime('%d.%m.%Y'),
				time        => $dt_dep->strftime('%H:%M:%S'),
				datetime    => $dt_dep,
				line        => $linename,
				line_id     => $lineid,
				destination => decode( 'UTF-8', $dest ),
				countdown =>
				  $dt_dep->subtract_datetime($dt_now)->in_units('minutes'),
				countdown_sec =>
				  $dt_dep->subtract_datetime($dt_now)->in_units('seconds'),
				route_timetable => [@route],
				stop            => $stopname,
				stop_id         => $stopid,
			)
		);
	}

	@results = map { $_->[0] }
	  sort { $a->[1] <=> $b->[1] }
	  map { [ $_, $_->countdown ] } @results;

	$self->{results} = \@results;

	return @results;
}

1;

__END__

=head1 NAME

Travel::Status::DE::ASEAG - unofficial ASEAG departure monitor

=head1 SYNOPSIS

    use Travel::Status::DE::ASEAG;

    my $status = Travel::Status::DE::ASEAG->new(
        stop => 'Aachen Bushof'
    );

    for my $d ($status->results) {
        printf(
            "%s  %-5s %25s (in %d min)\n",
            $d->time, $d->line, $d->destination, $d->countdown
        );
    }

=head1 VERSION

version 1.04

=head1 DESCRIPTION

Travel::Status::DE::ASEAG is an unofficial interface to an ASEAG departure
monitor. It reports all upcoming departures at a given place in real-time.
Schedule information is not included.

=head1 METHODS

=over

=item my $status = Travel::Status::DE::ASEAG->new(I<%opt>)

Requests the departures as specified by I<opts> and returns a new
Travel::Status::DE::ASEAG object.

Accepts the same options is C<< $status->results >>. Options specified here
can be overridden later, but may limit the set of available departures.


=item $status->errstr

In case of an HTTP request error, returns a string describing it. If none
occured, returns undef.

=item $status->results(I<%opt>)

Returns a list of Travel::Status::DE::ASEAG::Result(3pm) objects, each describing
one departure.

Accepted parameters (all are optional):

=over

=item B<full_routes> => B<before>|B<after>|I<bool> (default 0)

When set to a true value: Compute B<route_timetable> fields in all
Travel::Status::DE::ASEAG::Result(3pm) objects, otherwise they will not be
set.

B<before> / B<after> limits the timetable to stops before / after the stop
I<name> (if set).

=item B<fuzzy> => I<bool> (default 1)

A true value allows fuzzy matching for the I<name> set above, a false one
requires an exact string match.

=item B<hide_past> => I<bool> (default 1)

Do not include past departures in the result list and the computed timetables.

=item B<stop> => I<name>

Only return departures at stop I<name>.

=item B<via> => I<vianame>

Only return departures containing I<vianame> in their route. If B<stop> is set,
I<vianame> must be in the route after the stop I<name>. If, in addition to
that, B<full_routes> is set to B<before>, I<vianame> must be in the route
before the stop I<name>. Respects B<fuzzy>. Implies C<< full_routes> => 'after' >> unless
B<full_routes> is explicitly set to B<before> / B<after> / 1.

=back

=back

=head1 DIAGNOSTICS

None.

=head1 DEPENDENCIES

=over

=item * Class::Accessor(3pm)

=item * DateTime(3pm)

=item * LWP::UserAgent(3pm)

=back

=head1 BUGS AND LIMITATIONS

Many.

=head1 SEE ALSO

aseag-m(1), Travel::Status::DE::ASEAG::Result(3pm).

=head1 AUTHOR

Copyright (C) 2013 by Daniel Friesel E<lt>derf@finalrewind.orgE<gt>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.
