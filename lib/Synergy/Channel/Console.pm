use v5.36.0;
package Synergy::Channel::Console;

use utf8;

use Moose;

use Future::AsyncAwait;
use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;
use List::Util qw(max);

use Term::ANSIColor qw(colored);
use YAML::XS ();

with 'Synergy::Role::Channel';

has allow_eval => (
  is => 'ro',
  default => 0,
);

has color_scheme => (
  is  => 'ro',
  isa => 'Str',
);

has theme => (
  is    => 'ro',
  lazy  => 1,
  init_arg  => undef,
  handles   => [ qw(
    _format_wide_message
    _format_notice
    _format_message_compact
    _format_message_chonky
  ) ],
  default   => sub ($self) {
    return Synergy::TextThemer->from_name($self->color_scheme)
      if $self->color_scheme;

    return Synergy::TextThemer->null_themer;
  },
);

has ignore_blank_lines => (
  is => 'rw',
  isa => 'Bool',
  default => 1,
);

has from_address => (
  is  => 'rw',
  isa => 'Str',
  default => 'sysop',
);

has public_by_default => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

has public_conversation_address => (
  is  => 'rw',
  isa => 'Str',
  default => '#public',
);

has target_prefix => (
  is  => 'rw',
  isa => 'Str',
  default => '@',
);

has send_only => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has stream => (
  reader    => '_stream',
  init_arg  => undef,
  lazy      => 1,
  builder   => '_build_stream',
);

has message_format => (
  is => 'rw',
  default => 'chonky',
);

sub _build_stream {
  my ($channel) = @_;
  Scalar::Util::weaken($channel);

  open(my $cloned_stdout, '>&', STDOUT) or die "Can't dup STDOUT: $!";
  open(my $cloned_stdin , '>&', STDIN)  or die "Can't dup STDIN: $!";

  binmode $cloned_stdout, ':pop'; # remove utf8
  binmode $cloned_stdin,  ':pop'; # remove utf8

  my %arg = (
    write_handle => $cloned_stdout,
    encoding     => 'UTF-8',
    # autoflush    => 1,
  );

  unless ($channel->send_only) {
    $arg{read_handle} = $cloned_stdin;
    $arg{on_read}     = sub {
      my ($self, $buffref, $eof) = @_;

      while ($$buffref =~ s/^(.*\n)//) {
        my $text = $1;
        chomp $text;

        my $event = $channel->_event_from_text($text);
        next unless $event;

        $channel->hub->handle_event($event);
      }

      return 0;
    };
  }

  return IO::Async::Stream->new(%arg);
}

package Synergy::Channel::Console::DiagnosticHandler {

  use Moose;
  extends 'Synergy::DiagnosticHandler';

  use experimental qw(signatures);

  has channel => (is => 'ro', required => 1, weak_ref => 1);

  my %HELP;
  $HELP{console} = <<~'EOH';
  There are commands for inspecting and tweaking your Console channel.

    /console  - print Console channel configuration
    /format   - configure Console channel output (see "/help format")
    /history  - inspect messages previously sent across this channel

    /set VAR VALUE  - change the default value for one of the following

      from-address    - the default from_address on new events
      public          - 0 or 1; whether messages should be public by default
      public-address  - the default conversation address for public events
      target-prefix   - token that, at start of text, is stripped, making the
                        event targeted

  EOH

  $HELP{format} = <<~'EOH';
  You can toggle the format of messages sent to Console channels with the
  following values:

    compact - print the channel name and target address, then the text
    chonky  - print a nice box with the text wrapped into it

  Use these commands:

    /format WHICH         - set the output format for this channel
    /format WHICH CHANNEL - set the output format for another Console

  You can supply "*" as the channel name to set the format for all Console
  channels.
  EOH

  $HELP{history} = <<~'EOH';
  The history command lets you see messages sent across a Console channel,
  assuming you have history logging turned on.  Your Console channel will need
  a max_message_history setting greater than 1.

  It works like this:

      /history $message_number $format? $channel_name?

  The message number is shown on (chonky-formatted) messages in a Console
  channel, if it's logging history.  $format defaults to "text" and
  $channel_name defaults to the channel on which you're sending this command.
  This can be useful for using the Console environment for debugging non-text
  alternatives.

  So, given this message box:

    ╭─────┤ term-rw!rjbs #6 ├──────────────────────────────╮
    │ I don't know how to search for that!
    ╰──────────────────────────────────────────────────────╯

  You can enter "/history 6" to see the message re-displayed as text, or
  "/history 6 alts" to see the non-text alternatives dumped.
  EOH

  $HELP{events} = <<~'EOH';
  You can begin your message with a string inside braces.  The string is made
  up of instructions separated by spaces.  They can be:

    f:STRING      -- make this event have a different from address
    d:STRING      -- make this event have a different default reply address
    p[ublic]:BOOL -- set whether is_public
    t:BOOL        -- set event's was_targeted

  So to make the current message appear to be public and to come from "jem",
  enter:

    {p:1 f:jem} Hi!

  The braced string and any following spaces are stripped.
  EOH

  my %EXTRA;

  $EXTRA{''} = <<~'EOH';
You've connected to a Console channel, which also functions as a messaging
channel with Synergy.  If you send text that doesn't start with a slash, it
will become a message.  The following slash commands are also provided:

  console - commands for inspecting and configuring your Console channel
  events  - how to affect the events generated by your messages
  format  - commands to affect console output format

To send a message that begins with a literal "/", start with "//" instead.
EOH

  around _help_for => sub ($orig, $self, $arg) {
    $arg = defined $arg ? lc $arg : q{};
    my $help = $HELP{$arg} // $self->$orig($arg);

    if ($EXTRA{$arg}) {
      $help .= "$EXTRA{$arg}";
    }

    return $help;
  };

  sub _diagnostic_cmd_console ($self, $arg) {
    my $output = qq{Channel configuration:\n\n};

    my $channel = $self->channel;

    my $width = 15;
    $output .= sprintf "%-*s: %s\n", $width, 'name', $channel->name;
    $output .= sprintf "%-*s: %s\n", $width, 'theme', $channel->color_scheme // '(none)';
    $output .= sprintf "%-*s: %s\n", $width, 'default from', $channel->from_address;

    $output .= sprintf "%-*s: %s\n",
      $width, 'default context',
      $channel->public_by_default ? 'public' : 'private';

    $output .= sprintf "%-*s: %s\n",
      $width, 'public address',
      $channel->public_conversation_address;

    $output .= sprintf "%-*s: %s\n",
      $width, 'target prefix',
      $channel->target_prefix;

    return [ box => $output ];
  }

  sub _diagnostic_cmd_format ($self, $arg) {
    unless (length $arg) {
      return [ box => "Current format: " .  $self->channel->message_format ];
    }

    my ($format, $channel) = split /\s+/, $arg, 2;

    unless ($format eq 'chonky' or $format eq 'compact') {
      return [ box => "Not a valid message format." ];
    }

    $channel //= $self->channel->name;

    my @channels = grep {; $channel eq '*' || $_->name eq $channel }
                   grep {; $_->isa('Synergy::Channel::Console') }
                   $self->hub->channels;

    unless (@channels) {
      return [ box => "Couldn't find target Console reactor." ];
    }

    for (@channels) {
      $_->message_format($format);
      $_->_display_notice("Message format set to $format");
    }

    return [ box => 'Updated.' ];
  }

  # from-address    - the default from_address on new events
  # public          - 0 or 1; whether messages should be public by default
  # public-address  - the default conversation address for public events
  # target-prefix   - token that, at start of text, is stripped, making the
  #                   event targeted
  sub _diagnostic_cmd_set ($self, $rest) {
    unless (length $rest) {
      return [ box => "Usage: /set VAR VALUE" ];
    }

    my ($var, $value) = split /\s+/, $rest, 2;

    unless (length $var && length $value) {
      return [ box => "Usage: /set VAR VALUE" ];
    }

    my %var_handler = (
      'from-address'    => sub ($v) { $self->channel->from_address($v) },
      'public'          => sub ($v) { $self->channel->public_by_default($v ? 1 : 0); },
      'public-address'  => sub ($v) { $self->channel->public_conversation_address($v) },
      'target-prefix'   => sub ($v) { $self->channel->target_prefix($v) },
    );

    my $handler = $var_handler{$var};

    unless ($handler) {
      return [ box => "Unknown Console channel variable: $var" ];
    }

    eval {; $handler->($value) };

    if ($@) {
      return [ box => "Error occurred setting $var" ];
    }

    return [ box => "Updated $var" ];
  }

  sub _diagnostic_cmd_history ($self, $rest) {
    my ($number, $format, $channel_name) = split /\s+/, $rest, 3;

    $format = 'text' unless length $format;

    my $channel;

    if ($channel_name) {
      $channel = $self->hub->channel_named($channel_name);

      unless ($channel) {
        return [ box => "Unknown channel: $channel_name" ];
      }

      unless ($channel->DOES('Synergy::Channel::Console')) {
        return [ box => "That isn't a Console channel, so this won't work.  $channel" ];
      }
    } else {
      $channel = $self->channel;
      $channel_name = $channel->name;
    }

    unless ($channel->max_message_history > 0) {
      return [ box => "That reactor does not store message history." ];
    }

    unless ($number =~ /\A[0-9]+\z/) {
      return [ box => "That second argument doesn't look like a number." ];
    }

    my $message_log = $channel->_message_log;

    unless (@$message_log) {
      return [ box => "There's no history logged (yet?)." ];
    }

    my ($message) = grep {; $_->{number} == $number } @$message_log;

    unless ($message) {
      my $expired = $number < $message_log->[0]{number};
      if ($expired) {
        return [ box => "I can't find that message in history.  It probably expired." ];
      }

      return [ box => "There's no message in history with that number." ];
    }

    my %new_message = %$message;

    my $content
      = $format eq 'text' ? $channel->_format_message_chonky(\%new_message)
      : $format eq 'alts' ? YAML::XS::Dump($new_message{alts})
      : undef;

    unless ($content) {
      return [ box => "I don't know how to format things this way: $format" ];
    }

    my $title = "history: channel=$channel_name item=$number format=$format";

    return [ wide_box => $content, $title ];
  }

  sub _display_notice ($self, $text) {
    $self->stream->write($self->_format_notice($self->channel->name, $text));
    return;
  }

  no Moose;
}

has _diagnostic_handler => (
  is => 'ro',
  lazy => 1,
  handles => [ qw(_do_diagnostic_command) ],
  default => sub ($self) {
    Synergy::Channel::Console::DiagnosticHandler->new({
      stream  => $self->_stream,
      hub     => $self->hub,
      channel => $self,
      theme   => $self->theme,
      allow_eval => $self->allow_eval,
      ($self->color_scheme ? (color_scheme => $self->color_scheme) : ()),
    });
  },
);

sub _event_from_text ($self, $text) {
  # If we start with 2+ slashes, drop one and carry on like it was text
  # input.  If we start with exactly one slash, we shunt this command to the
  # diagnostics handler.
  if ($text =~ m{\A/} && $text !~ s{\A//}{/}) {
    return if $self->_do_diagnostic_command($text);

    $self->_display_notice("Didn't understand that diagnostic command.");
    return undef;
  }

  if (not length $text && $self->ignore_blank_lines) {
    return undef;
  }

  my $orig_text = $text;
  my $meta = ($text =~ s/\A \{ ([^}]+?) \} \s+//x) ? $1 : undef;

  my $is_public     = $self->public_by_default;

  my $target_prefix = $self->target_prefix;
  my $was_targeted  = $text =~ s/\A\Q$target_prefix\E\s+// || ! $is_public;

  my %arg = (
    type => 'message',
    text => $text,
    was_targeted  => $was_targeted,
    is_public     => $self->public_by_default,
    from_channel  => $self,
    from_address  => $self->from_address,
    transport_data => { text => $orig_text },
  );

  if (length $meta) {
    # Crazy format for producing custom events by hand! -- rjbs, 2018-03-16
    #
    # If no colon/value, booleans default to becoming true.
    #
    # f:STRING      -- change the from address
    # d:STRING      -- change the default reply address
    # p[ublic]:BOOL -- set whether is public
    # t:BOOL        -- set whether targeted
    my @flags = split /\s+/, $meta;
    FLAG: for my $flag (@flags) {
      my ($k, $v) = split /:/, $flag;

      if ($k eq 'f') {
        unless (defined $v) {
          $Logger->log([
            "console event on %s: ignoring valueless 'f' flag",
            $self->name,
          ]);
          next FLAG;
        }
        $arg{from_address} = $v;
        next FLAG;
      }

      if ($k eq 'd') {
        unless (defined $v) {
          $Logger->log([
            "console event on %s: ignoring valueless 'd' flag",
            $self->name,
          ]);
          next FLAG;
        }
        $arg{transport_data}{default_reply_address} = $v;
        next FLAG;
      }

      if ($k eq 't') {
        $v //= 1;
        $arg{was_targeted} = $v;
        next FLAG;
      }

      if ($k eq substr("public", 0, length $k)) {
        $v //= 1;
        $arg{is_public} = $v;
        next FLAG;
      }
    }
  }

  $arg{conversation_address}
    =   $arg{transport_data}{default_reply_address}
    //= $arg{is_public}
      ? $self->public_conversation_address
      : $arg{from_address};

  my $user = $self->hub->user_directory->user_by_channel_and_address(
    $self,
    $arg{from_address},
  );

  $arg{from_user} = $user if $user;

  return Synergy::Event->new(\%arg);
}

sub _display_notice ($self, $text) {
  $self->_stream->write($self->_format_notice($self->name, $text));
  return;
}

async sub start ($self) {
  $self->hub->loop->add($self->_stream);

  my $boot_message = "Console channel online";

  $boot_message .= "; type /help for help" unless $self->send_only;

  $self->_display_notice($boot_message);

  return;
}

has _next_message_number => (
  is => 'rw',
  init_arg => undef,
  default  => 0,
  traits   => [ 'Counter' ],
  handles  => { get_next_message_number => 'inc' },
);

has _message_log => (
  is => 'ro',
  init_arg => undef,
  default  => sub {  []  },
);

has max_message_history => (
  is => 'ro',
  default => 0,
);

sub _log_message ($self, $message) {
  return undef unless $self->max_message_history > 0;

  my $i = $self->get_next_message_number;

  $message->{number} = $i;

  my $log = $self->_message_log;
  push @$log, $message;

  if (@$log > $self->max_message_history) {
    shift @$log;
  }
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  $self->send_message($user->username, $text, $alts);
}

sub _format_message ($self, $message) {
  if ($self->message_format eq 'compact') {
    return $self->_format_message_compact($message);
  }

  return $self->_format_message_chonky($message);
}

sub send_message ($self, $address, $text, $alts = {}) {
  my $name = $self->name;

  my $message = {
    name    => $name,
    address => $address,
    text    => $text,
    alts    => $alts,
  };

  $self->_log_message($message);

  $self->_stream->write( $self->_format_message($message) );
}

sub send_ephemeral_message ($self, $conv_address, $to_address, $text) {
  my $name = $self->name;

  my $message = {
    name    => $name,
    address => $to_address,
    text    => "[ephemeral] $text",
    alts    => undef,
  };

  $self->_log_message($message);

  $self->_stream->write( $self->_format_message($message) );
}

sub describe_event ($self, $event) {
  return "(a console event)";
}

sub describe_conversation ($self, $event) {
  return "[console]";
}

1;
