#!/user/bin/perl

# This script is not so easily run anymore.  Refer to shell script
# to see what additional include directories and switches are needed.
use strict;
use warnings;
use utf8;
use Term::ProgressBar::Simple;
use PAPS::Database::papsdb::Schema;
use ParsCit::Controller;
use DateTime;
use DateTime::Format::Pg;

my $VERSION = 0.004;

my $verbose = 0;

my $schema = PAPS::Database::papsdb::Schema->connect('dbi:Pg:dbname=papsdb',
                                                     'papsuser', '',
                                                     {
                                                      pg_enable_utf8 => 1,
                                                     });

# Get the user's id value.  Die if it cannot be found.
my $user_name = 'RefMatch';
my $user = $schema->resultset('User')->find( { 'me.name' => $user_name }, undef );
die "$0: Error: User '${user_name}' not found.  Quitting.\n" unless $user;
my $user_id = $user->id;

# Get the algorithm's id value.  Die if it cannot be found.
my $algorithm_name = 'Levenshtein Distance';
my $algorithm = $schema->resultset('Algorithm')->find( { 'me.name' => $algorithm_name }, undef );
die "$0: Error: Id for algorithm '${algorithm_name}' not found.  Quitting.\n" unless $algorithm;
my $algorithm_id = $algorithm->id;

# Get the persona's id value.  Die if it cannot be found.
my $persona = $schema->resultset('Persona')->find(
                                                  {
                                                   'me.user_id' => $user_id,
                                                   'me.algorithm_id' => $algorithm_id,
                                                   'me.version' => $VERSION,
                                                  }, undef );
die "$0: Error: Id for persona for user id ${user_id}, algorithm id ${algorithm_id}, and version $VERSION not found.  Quitting.\n" unless $persona;
my $persona_id = $persona->id;

# Fetch the set of works
my $works_rs = $schema->resultset('Work');
my $works_count = $works_rs->count;

my $ref_count = $schema->resultset('WorkReference')->search( { 'me.referenced_work_id' => undef },
                                                         { order_by => [ 'referencing_work_id', 'id' ]})->count;
print "Number of references without a referenced work: " . $ref_count . "\n";

# Fetch the set of all references, sorted by the last time the reference was checked.
my $ref_rs = $schema->resultset('WorkReference')
  ->search(
           {
            -and => [
                     'me.referenced_work_id' => undef,
                     -or => [
                             'persona.algorithm_id' => undef,
                             'persona.algorithm_id' => {'=', $algorithm_id},
                             #'persona.version' => {'<=', $VERSION}
                            ]
                    ]
           },
           {
            join => { 'referenced_work_guesses' => 'persona' },
            '+select' => [ 'persona.user_id', 'persona.algorithm_id',
                           'persona.version', 'referenced_work_guesses.last_checked',
                           'referenced_work_guesses.confidence' ],
            '+as' => [ 'p_user_id', 'p_algorithm_id', 'p_version', 'rwg_last_checked', 'rwg_confidence' ],
            order_by => [ 'referenced_work_guesses.last_checked ASC NULLS FIRST', 'referencing_work_id', 'id' ]
           });

# Note: the above search is not completely correct.  It will not return rows
# that have been process by other algorithms, only those that have been never
# processes or processed by this algorithm.  The search conditions on the
# persona table need to be in the ON clause of the JOIN, not in the WHERE
# clause.  DBIx::Class does not support this currently, so, most likely, a
# custom view must be created.  The SQL should be something like:
#
# SELECT me.id, me.referencing_work_id, me.referenced_work_id,
# 	me.reference_type_id, me.rank, me.chapter,
# 	me.reference_text, me.persona_id, me.modified,
# 	persona.user_id, persona.algorithm_id, persona.version,
# 	referenced_work_guesses.last_checked, referenced_work_guesses.confidence
# FROM work_references me
# LEFT JOIN referenced_work_guesses referenced_work_guesses ON referenced_work_guesses.work_reference_id = me.id
# LEFT JOIN personas persona ON persona.id = referenced_work_guesses.persona_id
# 	and (persona.algorithm_id is null or persona.algorithm_id = 2)
# WHERE ( me.referenced_work_id IS NULL )
# ORDER BY referenced_work_guesses.last_checked ASC NULLS FIRST, referencing_work_id, id;

if ($verbose) {
  while (my $ref = $ref_rs->next) {
    print $ref->id . "\t" . ($ref->get_column('rwg_last_checked') || "null") . "\t" . $ref->reference_text . "\n";
  }
  $ref_rs->reset;
}

if ($verbose) {
  print "Works\n";
  while (my $work = $works_rs->next) {
    print $work->id . "\t" . $work->display_name . "\n";
  }
  $works_rs->reset;
}

# Store the first reference, as we will be using it later.
my $ref = $ref_rs->next;
if ($verbose) {
  print ("=" x 80);
  print "\n";
  print $ref->id . "\t" . ($ref->get_column('rwg_last_checked') || "null") . "\t" . $ref->reference_text . "\n";
}

# Create temp file to hold references.
my $fh;
my $temp_file_name = 'data/temp-ref-match' . time;
open($fh, ">", $temp_file_name) or die "$0: Cannot open temp file '$temp_file_name' for writing: $!\n";
print $fh "References\n";

print $fh $ref->reference_text . "\n\n";
## Add each reference's string to temp file.
#while (my $ref = $ref_rs->next) {
#  print $fh $ref->reference_text . "\n\n";
#}
#$ref_rs->reset;
close($fh);

# Use ParsCit to parse citations.
my @parse_output = ParsCit::Controller::ExtractCitationsImpl($temp_file_name);

## Pick a random citation to compare against the works.
#my $citations = $parse_output[2];
#my $citation_index = int(rand(@{ $citations }));
#my $citation = $citations->[$citation_index];

# Pick the first citation
my $citations = $parse_output[2];
my $citation = $citations->[0];

if (!$citation) {
  print "Warning: Failed to parse any citations.  Using full reference text to create a dummy citation.\n";
  $citation = ParsCit::Citation->new();
  $citation->setString($ref->reference_text);
  $citation->setTitle($citation->getString);
}

print "\n";
#print "Using citation #" . $citation_index . ".\n";
print "Using citation #0.\n";
print "Id:                  " . $ref->id . "\n";
print "Referencing work id: " . $ref->referencing_work_id . "\n";
print "Referenced work id:  " . ($ref->referenced_work_id || "null") . "\n";
print "Reference type id:   " . ($ref->reference_type_id || "null") . "\n";
print "Chapter:             " . ($ref->chapter || "null") . "\n";
print "Rank:                " . ($ref->rank || "null") . "\n";
print "Title:               " . ($citation->getTitle || "<Unknown>") . "\n";
print "Full text:           " . $citation->getString . "\n";
print "\n";

# Use the whole reference text if a title could not be parsed.
if (!$citation->getTitle || length($citation->getTitle) <= 0) {
  print "Warning: Could not extract title from citation.  Using full reference text for title.\n\n";
  $citation->setTitle($citation->getString);
}

# Initialize a progress bar.
my $progress = Term::ProgressBar::Simple->new($works_count);

my ($min_distance, $min_first_exploded, $min_second_exploded, $min_steps, $min_work) =
  (length($citation->getTitle) * 1000, "", "", "", undef);

# Iterate through each work and compute its Levenshtein distance
# with the selected reference.  Only print each work's results if
# we want verbose output.  Store the best match's info as we go along.
$progress->message("Searching for best match...");
while (my $work = $works_rs->next) {
  my ($distance, $first_exploded, $second_exploded, $steps) =
    levenshtein_distance_detailed($citation->getTitle, $work->display_name);
  $progress->message("Distance: $distance") if $verbose;
  $progress->message("$first_exploded") if $verbose;
  $progress->message("$second_exploded") if $verbose;
  $progress->message("$steps") if $verbose;
  $progress->message("\n") if $verbose;

  if ($distance < $min_distance) {
    $min_distance = $distance;
    $min_first_exploded = $first_exploded;
    $min_second_exploded = $second_exploded;
    $min_steps = $steps;
    $min_work = $work;
  }
  $progress++;
}

my $match_percent = ((length($citation->getTitle) - $min_distance) / length($citation->getTitle));
# Print out the results.
print "\n\n";
print "Best match:\n";
print "-----------\n";
print "Work id: " . $min_work->work_id . "\n";
print "Distance: $min_distance\n";
print "Reference length: " . length($citation->getTitle) . "\n";
print "Work length:      " . length($min_work->display_name) . "\n";
print "Length ratio:     " . (length($min_work->display_name) / length($citation->getTitle)) . "\n";
print "Match percent:    " . $match_percent . "\n";
print "\n";
print "Work display name: " . $min_work->display_name . "\n";
print "Reference text:    " . $citation->getTitle . "\n";
print "\n";
print "$min_first_exploded\n";
print "$min_second_exploded\n";
print "$min_steps\n";
print "\n";

my $current_date_time = DateTime->now();
$current_date_time->set_time_zone('America/New_York'); # This should be configurable, though, of course.
my $pg_timestamp = DateTime::Format::Pg->format_timestamp_with_time_zone($current_date_time);

my $result = $schema->resultset('ReferencedWorkGuess')
  ->update_or_create(
                     {
                      work_reference_id => $ref->id,
                      guessed_referenced_work_id => $min_work->id,
                      confidence => $match_percent,
                      persona_id => $persona_id,
                      last_checked => $pg_timestamp,
                     });

# Test Levenshtein distance algorithm if two strings are provided.
my ($first_string, $second_string) = @ARGV;
if (defined $first_string && defined $second_string) {
  test_distance($first_string, $second_string);
}
else {
  print "Skipping Levenshtein test -- no strings provided on imput.\n";
}


sub test_distance {
  my ($first_string, $second_string) = @_;

  print "Testing Levenshtein distance.\n";
  print "first: $first_string\n";
  print "second: $second_string\n";

  my ($distance, $first_exploded, $second_exploded, $steps) = levenshtein_distance_detailed($first_string, $second_string);

  print "Levenshtein distance between '$first_string' and '$second_string': $distance.\n";
  print "$first_exploded\n";
  print "$second_exploded\n";
  print "$steps\n";
}



sub levenshtein_distance {
  no warnings 'recursion';

  my ($s, $t, $memo) = @_;
  $memo ||= { };

  my ($len_s, $len_t) = (length($s), length($t));
  my $key = "$s|$t";

  if (defined $memo->{$key}) {
    #print "Using memoization of key '$key' ($memo->{$key}).\n";
    my $value = $memo->{$key};
    return $value;
  }
  
  return $len_s if $len_t == 0;
  return $len_t if $len_s == 0;

  my $cost = uc(substr($s, -1, 1)) ne uc(substr($t, -1, 1));

  my ($first, $second, $third);
  $first = levenshtein_distance(substr($s, 0, $len_s - 1), $t, $memo) + 1;
  $second = levenshtein_distance($s, substr($t, 0, $len_t - 1), $memo) + 1;
  $third = levenshtein_distance(substr($s, 0, $len_s - 1), substr($t, 0, $len_t - 1), $memo) + $cost;

  my $min = $first < $second ? $first : $second;
  $min = $min < $third ? $min : $third;

  #print "dist of '$s' and '$t' is $min.\n";
  $memo->{$key} = $min;
  return $min;
}

sub levenshtein_distance_detailed {
  no warnings 'recursion';

  my ($s, $t, $s_s, $s_t, $a, $memo) = @_;
  $s_s ||= "";
  $s_t ||= "";
  $a ||= "";
  $memo ||= { };

  my ($len_s, $len_t) = (length($s), length($t));
  my $key = "$s|$t";

  if (defined $memo->{$key}) {
    #print "Using memoization of key '$key' ($memo->{$key}).\n";
    my ($value, $k_s, $k_t, $k_a) = split(/\|/, $memo->{$key});
    return ($value, $k_s, $k_t, $k_a);
  }
  
  return ($len_s, $s, " " x $len_s, "i" x $len_s) if $len_t == 0;
  return ($len_t, " " x $len_t, $t, "i" x $len_t) if $len_s == 0;

  my $cost = uc(substr($s, -1, 1)) ne uc(substr($t, -1, 1));

  my ($first, $second, $third);
  my ($s_s1, $s_t1, $a1, $s_s2, $s_t2, $a2, $s_s3, $s_t3, $a3);
  ($first, $s_s1, $s_t1, $a1) = levenshtein_distance_detailed(substr($s, 0, $len_s - 1), $t, $s_s, $s_t, $a, $memo);
  $first = $first + 1;
  ($second, $s_s2, $s_t2, $a2) = levenshtein_distance_detailed($s, substr($t, 0, $len_t - 1), $s_s, $s_t, $a, $memo);
  $second = $second + 1;
  ($third, $s_s3, $s_t3, $a3) = levenshtein_distance_detailed(substr($s, 0, $len_s - 1), substr($t, 0, $len_t - 1), $s_s, $s_t, $a, $memo);
  $third = $third + $cost;

  if ($first <= $second && $first <= $third) {
    $s_s = $s_s1 . substr($s, -1, 1);
    $s_t = $s_t1 . " ";
    $a = $a1 . "i";
  }
  elsif ($second <= $first && $second <= $third) {
    $s_s = $s_s2 . " ";
    $s_t = $s_t2 . substr($t, -1, 1);
    $a = $a2 . "i";
  }
  else {
    $s_s = $s_s3 . substr($s, -1, 1);
    $s_t = $s_t3 . substr($t, -1, 1);
    $a = $cost == 0 ? $a3 . " " : $a3 . "s";
  }

  my $min = $first < $second ? $first : $second;
  $min = $min < $third ? $min : $third;

  #print "dist of '$s' and '$t' is $min.\n";
  #print "$s_s\n";
  #print "$s_t\n";
  #print "$a\n";
  $memo->{$key} = $min . "|" . $s_s . "|" . $s_t . "|" . $a;
  return ($min, $s_s, $s_t, $a);
}
