#!/user/bin/perl

# easily use this script with
#  perl -I../PAPS-Database-papsdb-Schema/lib/ refmatch.pl
use strict;
use warnings;
use PAPS::Database::papsdb::Schema;

my $schema = PAPS::Database::papsdb::Schema->connect('dbi:Pg:dbname=papsdb',
                                                     'papsuser', '');

# Fetch the set of works
my $works_rs = $schema->resultset('Work');

# Fetch the set of all references, sorted by referencing work
my $ref_rs = $schema->resultset('WorkReference')->search('me.referenced_work_id' => undef,
                                                         { order_by => [ 'referencing_work_id', 'id' ]});
my $ref_count = $ref_rs->count;
print "Number of references without a referenced work: " . $ref_count . "\n";

print "Works\n";
while (my $work = $works_rs->next) {
  print $work->id . "\t" . $work->display_name . "\n";
}
$works_rs->reset;

print "Referneces\n";
while (my $ref = $ref_rs->next) {
  print $ref->id . "\t" . ($ref->referencing_work_id || "null") . "\t" . $ref->reference_text . "\n";
}
$ref_rs->reset;

my $reference_index = int(rand($ref_count));
my ($ref) = $ref_rs->slice($reference_index, $reference_index);
print "Using reference #" . $reference_index . ": " . $ref->reference_text . "\n";
# now compare the first reference against all works using the levenshtein
# distance
#my $ref = $ref_rs->next;
#print "Testing reference (" . $ref->id . " ): " . $ref->reference_text . "\n";
my ($min_distance, $min_first_exploded, $min_second_exploded, $min_steps) = (length($ref->reference_text) * 1000, "", "", "");
while (my $work = $works_rs->next) {
  my ($distance, $first_exploded, $second_exploded, $steps) = levenshtein_distance_detailed($ref->reference_text, $work->display_name);
  print "Distance: $distance\n";
  print "$first_exploded\n";
  print "$second_exploded\n";
  print "$steps\n";
  print "\n";
  #print $work->id . "\t" . $work->display_name . "\n";

  if ($distance < $min_distance) {
    $min_distance = $distance;
    $min_first_exploded = $first_exploded;
    $min_second_exploded = $second_exploded;
    $min_steps = $steps;
  }
}

print (("=" x 80) . "\n");
print "Minimum values found.\n";
print "Distance: $min_distance\n";
print "$min_first_exploded\n";
print "$min_second_exploded\n";
print "$min_steps\n";
print "\n";

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
