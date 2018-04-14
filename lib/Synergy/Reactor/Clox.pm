use v5.24.0;
package Synergy::Reactor::Clox;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first uniq);

sub listener_specs {
  return {
    name      => 'clox',
    method    => 'handle_clox',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text eq 'clox' },
  };
}

has time_zone_names => (
  is  => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
);

sub handle_clox ($self, $event, $rch) {
  $event->mark_handled;

  my $now = DateTime->now;

  my @tzs = sort {; $a cmp $b }
            uniq
            grep {; defined }
            map  {; $_->time_zone }
            $self->hub->user_directory->users;
  my @times;

  my $tz_nick = $self->time_zone_names;

  for my $tz_name (@tzs) {
    my $tz = DateTime::TimeZone->new(name => $tz_name);
    my $tz_now = $now->clone;
    $tz_now->set_time_zone($tz);

    use utf8;
    my $str = $tz_nick->{$tz_name}
            ? $tz_now->format_cldr("H:mm") . " $tz_nick->{$tz_name}"
            : $tz_now->format_cldr("H:mm vvv");

    push @times, $tz_now->day_name . ", $str";
  }

  my $sit = $now->clone;
  $sit->set_time_zone('+0100');

  push @times, $sit->ymd('-') . '@'
      . int(($sit->second + $sit->minute * 60 + $sit->hour * 3600) / 86.4);

  $rch->reply(join('; ', @times));
}

1;
