require Exporter;
use strict;
use feature qw(state switch);
use threads;
use threads::shared;
use Thread::Queue;
use Thread::Semaphore;
use Fcntl;
use Hash::Merge;
use Time::HiRes qw(time usleep);
use Term::ANSIColor qw(:constants);
use Time::Local;

use Data::Printer;

sub metric{  Logster->_enqueue_wrap( {&Logster::L_METRIC  => [ @_ ]} ) }
sub debug{   Logster->_enqueue_wrap( {&Logster::L_DEBUG   => [ @_ ]} ) }
sub info{    Logster->_enqueue_wrap( {&Logster::L_INFO    => [ @_ ]} ) }
sub warning{ Logster->_enqueue_wrap( {&Logster::L_WARNING => [ @_ ]} ) }
sub error{   Logster->_enqueue_wrap( {&Logster::L_ERROR   => [ @_ ]} ) }
sub fatal{   Logster->_enqueue_wrap( {&Logster::L_FATAL   => [ @_ ]} ) }


package Logster {

our $VERSION = 1.999_001;
our @ISA = qw(Exporter);
our @EXPORT = qw( L_DATE_BIGEND L_DATE_MIDEND L_DATE_LITEND L_DATE_ISO8601 
                  L_TIME_24HR L_TIME_12HR );
# our @export_ok = qw(set_debug_level set_file_debug_level log_to_file stop_log_to_file logmsg logmsg_nocr logmsg_nostamp logmsg_nostamp_nocr set_hires_timestamp
                    # l_none l_debug l_info l_warning l_error l_critical
                    # colors_off set_stderr set_stdout
					# metric debug info warning error fatal);
# our %export_tags = (all => \@export_ok);

$Term::ANSIColor::AUTORESET = 1;

our $q                  = Thread::Queue->new;
my $_flushing           = Thread::Semaphore->new();
my $_printing           = Thread::Semaphore->new();
my $_dequeueing         = Thread::Semaphore->new();
my $_single    : shared = threads::shared::shared_clone({});
my $_thread_id : shared;
my $_destroy   : shared;
my %_cfg       : shared;

sub new
{
	my $class = shift;
	my $in_cfg = {};
	my $gmt_diff = (localtime(Time::Local::timegm(localtime)))[2]
				   - (localtime)[2];
	my ($filename) = $0 =~ m/(.+)\.\w+$/;
	my $singleton_created = 0;
	$filename .= '.log';
	
	if(ref $_[0])
	{
		$in_cfg = $_[0];
	}
	else
	{
		my %a = @_;
		$in_cfg = \%a;
	}
	
	unless(ref $_single eq $class)
	{
		threads::shared::bless($_single, $class);
		$singleton_created = 1;
		# print 'C';
	}
	# print "NEW " . $_single . "\n";
	
	if($singleton_created)
	{
		%_cfg = ( colors               => 1,
				
				  show_date            => 1,
				  date_format          => $_single->L_DATE_BIGEND,
						 
				  show_time            => 1,
				  show_meridian        => 1,
				  time_format          => $_single->L_TIME_24HR,
				  show_timezone        => 0,
     			  timezone             => $gmt_diff,
				  highres_time         => 0,
						 
				  show_verbosity       => 1,
						
				  show_tid             => 0,
			      show_pid             => 0,
				  show_caller          => 0,
				  show_linenum         => 0,

				  newline              => "\n",
						 
				  output_fh            => *STDOUT,
				  verbosity_level      => $_single->L_INFO,
				  autoflush            => 0,
						 
				  log_to_file          => 0,
				  logfile_fd           => undef,
				  truncate_logfile     => 0,
				  file_verbosity_level => $_single->L_INFO,
				  logfile_name         => $filename );
	}
	
	if($in_cfg->{log_to_file})
	{
		unless($in_cfg->{logfile_name})
		{
			my $fn = $0;
			$fn =~ s/(?:\..+|)$/.log/;
			$in_cfg->{logfile_name} = $fn;
		}
		my $opts = Fcntl::O_WRONLY | Fcntl::O_CREAT;
		$opts |= Fcntl::O_TRUNC if $in_cfg->{truncate_logfile};
		
		sysopen(FILE, $in_cfg->{logfile_name}, $opts)
			or print 'Logster unable to open ' . $in_cfg->{logfile_name} . ": $!\n";
		$in_cfg->{logfile_fd} = fileno(FILE);
	}
	
	# Data::Printer::p $in_cfg;
	# Data::Printer::p FILE;
	
	if(%$in_cfg)
	{
		$_single->_cfg($in_cfg);
	}
	
	$_destroy = 0;
	
	unless(defined $_thread_id)
	{
		threads->create('_poller');
	}
	
	Time::HiRes::usleep 1_000 while( ! $_thread_id );
	# print "RETURN SINGLETON TID=$_thread_id\n";
	return $_single;
}

sub _cfg
{
	shift;
	my $in_cfg = shift;
	my $self = $_single;
	
	
	if( defined $in_cfg )
	{
		$_printing->down();
		merge_shallow(\%_cfg, $in_cfg);
		$_printing->up();
	}
	return \%_cfg;
}

sub _poller
{
	my $self = $_single;
	# print "+THREAD CREATED $self TID=" . threads->tid() . "\n";
	
	$SIG{KILL} = sub{ #print "+SIGNAL RECEIVED\n";
				      threads->exit(); };
	
	$_thread_id = threads->tid();
	
	while( ! $_destroy )
	{
		$_dequeueing->down();
		# print "+D         LOCK\n";
		if( my $msg = $Logster::q->dequeue() )
		{
			$_dequeueing->up();
			# print "+D         free\n";
			
			$_printing->down();
			# print "+P:  LOCK\n";
			my($v,$m) = each %$msg;
			
			# print "+CALLING LOGMSG\n";
			$self->logmsg($v, @$m);
		
			$_printing->up();
			# print "+P:  free\n";
			
		}
		else
		{
			$_dequeueing->up();
			# print "+D               free\n";
		}
	}
	# print "+THREAD EXITING\n";
}

sub flush
{
	# print "-EMPTY QUEUE\n";
	my $self = $_single;
	
	$_flushing->down(); #prevent other threads from parallel flushing
	# print "-F:              LOCK\n";
	$_dequeueing->down_force();
	# print "-D:        LOCK\n";
	
	$_printing->down();  #prevent further polling
	# print "-P:  LOCK\n";
	
	while(my $msg = $Logster::q->dequeue_nb())
	{
		my($v,$m) = each %$msg;
		# print "-CALLING LOGMSG\n";
		$self->logmsg($v, @$m);
	}
	
	$_printing->up();
	# print "-P:  free\n";
	$_dequeueing->up();
	# print "-D:        free\n";
	$_flushing->up();
	# print "-F:              free\n";
	# print "-DONE\n";
}

sub done
{
	$_destroy = 1;
	flush();
	# print "!DESTRUCT SIGNAL\n";
	threads->object($_thread_id)->kill('KILL');
	# print "!RELEASE QUEUE LOOP\n";
	$Logster::q->enqueue(undef);
	# print "!REAPING THREAD\n";
	threads->object($_thread_id)->join();
	# print "!THREAD REAPED\n";
}

sub kill
{
	$_destroy = 1;
	threads->object($_thread_id)->kill('KILL');
	threads->object($_thread_id)->join();
}

sub _enqueue_wrap
{
	shift;
	my $self = $_single;
	return if $Logster::_destroy;
	$Logster::q->enqueue(@_);
}

sub logmsg
{
    shift;
    my $self = $_single;
	my $ticks = Time::HiRes::time;
	my($v,$msg) = @_;
	my $entry = '';
	my($seconds, $fraction) = ( int($ticks), $ticks - int($ticks) );
	
	return () if $v < $_cfg{verbosity_level};
	
	my @timestamp = ( prep_time(localtime($seconds)), $fraction );
	
	my $color = '';
	if($_cfg{colors})
	{
		if($v == $self->L_METRIC){
			{ $color = Term::ANSIColor::BLUE . Term::ANSIColor::ON_WHITE . Term::ANSIColor::BOLD } }
		elsif($v == $self->L_DEBUG){
			{ $color = Term::ANSIColor::CYAN } }
		elsif($v == $self->L_INFO){
			{ $color = Term::ANSIColor::GREEN } }
		elsif($v == $self->L_WARNING){
			{ $color = Term::ANSIColor::YELLOW } }
		elsif($v == $self->L_ERROR){
			{ $color = Term::ANSIColor::RED } }
		elsif($v == $self->L_FATAL){
			{ $color = Term::ANSIColor::MAGENTA } }
	}
	
    if($_cfg{show_date})
    {
        $entry .= $self->get_date(@timestamp) . ' ';
    }
    
	if($_cfg{show_time})
    {
        $entry .= $self->get_time(@timestamp) . ' ';
    }
    
    if($_cfg{show_time} or $_cfg{show_date})
    {
        $entry .= '| ';
    }
    
    if($_cfg{show_verbosity})
    {
		if($v == $self->L_METRIC){
			{ $entry .= 'METRIC ' } }
		elsif($v == $self->L_DEBUG) {
			{ $entry .= 'DEBUG  ' } }
		elsif($v == $self->L_INFO)  {
			{ $entry .= 'INFO   ' } }
		elsif($v == $self->L_WARNING){{
			$entry .= 'WARN   ' } }
		elsif($v == $self->L_ERROR) {
			{ $entry .= 'ERROR  ' } }
		elsif($v == $self->L_FATAL) {
			{ $entry .= 'FATAL  ' } }
        $entry .= '| ';
    }
    
	$entry .= $msg;
	
	if($_cfg{log_to_file})
	{
		open(FH, ">&=" . $_cfg{logfile_fd})
			or print "Could not connect to file descriptor: $!\n";
		print FH $entry . $_cfg{newline};
		close FH;
	}
	
	print $color . "$entry" . Term::ANSIColor::CLEAR . $_cfg{newline}
}

sub get_time
{
	shift;
	my $self = $_single;
	my $cfg = $self->_cfg();
	my($sec,$min,$hour,$isdst,$msec) = @_[0,1,2,8,9];
	$msec *= 1_000_000;

	my $time = '';
	if($cfg->{time_format} == $self->L_TIME_12HR)
	{
		if($hour > 12)
		{
			$hour %= 12;
			$hour++;
		}
	}
	$time  = sprintf("%02d:%02d:%02d", $hour, $min, $sec);
	$time .= sprintf(".%06d", $msec) if $cfg->{highres_time};
	$time .= sprintf(" %s", ($hour > 12 ? "PM" : "AM")) if $cfg->{show_meridian};
	
	return $time;
}

sub get_date
{
	shift;
	my $self = $_single;
	my $cfg = $self->_cfg();
	my($mday,$mon,$year) = @_[3,4,5];

	my @date = ();
	if($cfg->{date_format} == $self->L_DATE_BIGEND){
		{ @date = ($year, $mon, $mday) } }
	elsif($cfg->{date_format} == $self->L_DATE_MIDEND){
		{ @date = ($mon, $mday, $year) } }
	elsif($cfg->{date_format} == $self->L_DATE_LITEND){
		{ @date = ($mday, $mon, $year) } }

	return sprintf("%02d/%02d/%02d", @date);
}

sub merge_shallow
{
    my $left = shift;
    my $right = shift;
    my $changed = 0;
	
    while(my($k,$v) = each $right)
    {
        $left->{$k} = $v;
    }
}

sub prep_time
{
	my @timestamp = @_;
	$timestamp[5] += 1900;
	$timestamp[4]++;
	return @timestamp;
}


sub L_METRIC  { 1 };
sub L_DEBUG   { 2 };
sub L_INFO    { 3 };
sub L_WARNING { 4 };
sub L_ERROR   { 5 };
sub L_FATAL   { 6 };

sub L_TIME_24HR    { 1 };
sub L_TIME_12HR    { 2 };

sub L_DATE_BIGEND  { 1 };
sub L_DATE_ISO8601 { L_DATE_BIGEND };
sub L_DATE_MIDEND  { 2 };
sub L_DATE_LITEND  { 3 };


1;
}
