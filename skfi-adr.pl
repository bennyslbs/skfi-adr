#!/usr/bin/perl

use strict;
use warnings;

use Smart::Comments;

use IO::File;
use File::Slurp;
use YAML;

use File::stat;
use POSIX;
#use MIME::Base64;	  # Only needed for storing pictures in vcards

my $client_uuid = '228e3e02-e9c3-4aa1-9918-85d5851f419d';

my (%opts);
use Getopt::Long qw(:config no_ignore_case);
my $passed = GetOptions (
  "help"               => \$opts{h},
  "quiet"              => \$opts{q},
  "verbose"            => \$opts{v},
  "out-file-base=s"    => \$opts{out_file_base},
  "in-file-base=s"     => \$opts{in_file_base}, # Eg. ./0. - optional trailing . will be removed
  "Org=s"              => \$opts{org}, # Organization in exported VCARDs - defaults to class name, e.g. 0A
  "common-postfix=s"   => \$opts{common_postfix}, # Appended to out_file_base, in_file_base and Org
 );

if (not $passed) {
  usage();
}

if (!defined $opts{in_file_base}) {
  print "Option -i is needed\n";
  usage();
}

if (!defined $opts{out_file_base}) {
  print "Option -o is needed\n";
  usage();
}

# Add common postfix if defined
if (defined $opts{common_postfix}) {
  $opts{in_file_base} .= $opts{common_postfix};
  $opts{out_file_base} .= $opts{common_postfix};
  if (defined $opts{org}) {
    $opts{org} .= $opts{common_postfix};
  }
}

if (defined $opts{h}) {
  help();
}

sub print_help_msg {
  print "Usage: $0 [-q] [-v] [-h|-i <Input Filenames Base> -o <Output Filenames Base> [-O <OrganisationName>] [-c <Common postfix, appended to -i, -o, -O (-O only if -O specified)>]
Where
<Filename Base> is the common part of the file names.
Trailing part of file names:
- .navne.txt *)			(From Forældreintra)
- .elev_kontakt.txt *)		(From Forældreintra)
- .elev_email.txt *)		(From Forældreintra)
- .elev_fodselsdag.txt *)	(From Forældreintra)
- .kontaktoplysninger.txt *)	(From Forældreintra)
- .foraeldre_email.txt *)	(From Forældreintra)
- .contact_modifications.txt
  (YAML file with common modifications + extra info compared to Forældreintra)
- private_contact_modifications.txt
  (YAML file with private modifications + extra info compared to Forældreintra -
  same syntax as contact_modifications.txt, but for personal use)

*) The content in the files marked *) can be concatenated into
   one common file with trailing part: '.txt'.
   Note: If one of the above files exists it will be read instead of the
   common file => common file is only used for 'files' that are NOT as
   separate files.

   The parsing of the common file is based on the header/footer lines
   from Forældreintra.
   It is allowed with custom user separation between the different contents.
   Header lines are (X=The class identifyer, e.g. 0A):
   - Navneliste for X
   - Adresse\- og telefonliste for X
   - Liste over X's e-mailadresser
   - Oversigt over fødselsdage i X
   - Kontaktoplysninger i X
   - Forældrenes e-mailadresser i X
   Footer lines are identified by a line
   starting with optional spaces followed by FORÆLDREINTRA.

Example template for common data file
(with org-mode user-headers - can be deleted/edited/...):
# -*-org-*-
* Extrakt d. 20xx.xx.xx
** xA Kl.

*** Navneliste

*** Adresse- og telefonliste

*** Elevernes e-mailadresser

*** Elevernes fødselsdage

*** Kontaktoplysninger

*** Forældrenes e-mailadresser

";
}

  sub usage {
    print_help_msg();
    exit 1;
  }

sub help {
  print_help_msg();
  exit 0;
}

my %cfg;
#$cfg{file_ending}{student_list} = '.navne.txt';
$cfg{file_ending}{student_adr_phone} = '.elev_kontakt.txt';
$cfg{file_ending}{student_email} = '.elev_email.txt';
$cfg{file_ending}{student_birthday} = '.elev_fodselsdag.txt';
$cfg{file_ending}{parents_contact} = '.kontaktoplysninger.txt';
$cfg{file_ending}{parents_email} = '.foraeldre_email.txt';
my $file_ending_common = '.txt'; # Content from the above files can be located in a common file with this ending

$cfg{file_ending_mod}{contact_modifications} = '.contact_modifications.txt';
$cfg{file_ending_mod}{private_contact_modifications} = '.private_contact_modifications.txt';

my $opt_file_ending_ids = ''; # Regexp - | separator if multiple optional files exists in $cfg{file_ending}{<id>}

$opts{in_file_base} =~ s/\.$//; # Remove optional trailing . from in_file_base
$opts{out_file_base} =~ s/\.$//; # Remove optional trailing . from out_file_base

# Genders - static variables
use File::Basename;

# Get list of known boy names
my %genders;
getGenderListFromFiles(\%genders, 'b', dirname($0).'/internal_data'.'/navne.drenge.dat');
getGenderListFromFiles(\%genders, 'g', dirname($0).'/internal_data'.'/navne.piger.dat');

my %modTime;
$modTime{min} = 2**31;
$modTime{max} = -2**31;
my $missing = 0;
while (my ($id, $fEnding) = each %{$cfg{file_ending}}) {
  my $file = $opts{in_file_base}.$fEnding;
  if (-e $file) {
    my $time = stat($file)->mtime;
    $modTime{min} = $time if ($time < $modTime{min});
    $modTime{max} = $time if ($time > $modTime{max});
  }
  elsif (-e $opts{in_file_base}.$file_ending_common) {
    $file = $opts{in_file_base}.$file_ending_common;
    $cfg{file_ending}{$id} = $file_ending_common;
    my $time = stat($file)->mtime;
    $modTime{min} = $time if ($time < $modTime{min});
    $modTime{max} = $time if ($time > $modTime{max});
  }
  elsif ($id !~ m/^($opt_file_ending_ids)$/) { # Report if non-optional file is missing
    print STDERR "Error: File is missing: $file\n";
    $missing++;
  }
}
if ($missing) {
  print STDERR "Error: Stop processing - can't work without required data files (listed above).\n";
}

my @students;			# Array with students
my %kl; # Hash with class info from each file - can be used to verify the files are for the same class
my %contacts;			# Contact info

#getStudentNames({opts => \%opts, cfg => \%cfg, students => \@students, kl => \%kl});
GetStudentAdrPhone({opts => \%opts, cfg => \%cfg, students => \@students, kl => \%kl, contacts => \%contacts});
GetStudentEmail({opts => \%opts, cfg => \%cfg, students => \@students, kl => \%kl, contacts => \%contacts});
GetStudentBirthday({opts => \%opts, cfg => \%cfg, students => \@students, kl => \%kl, contacts => \%contacts});
GetParentsContactInfo({opts => \%opts, cfg => \%cfg, students => \@students, kl => \%kl, contacts => \%contacts});
GetParentsEmail({opts => \%opts, cfg => \%cfg, students => \@students, kl => \%kl, contacts => \%contacts});
my $kl = $kl{(keys %kl)[0]};	# Get class from one of the elements

# Common modifications
ApplyContactModifications({contacts => \%contacts, kl => $kl, modFile => $opts{in_file_base}.$cfg{file_ending_mod}{contact_modifications}});
# Private modifications
ApplyContactModifications({contacts => \%contacts, kl => $kl, modFile => $opts{in_file_base}.$cfg{file_ending_mod}{private_contact_modifications}});
my $missingGender = RequestMissingGenerInformation({verbose => $opts{v}, contacts => \%contacts, commonDataFile => $opts{in_file_base}.$cfg{file_ending_mod}{contact_modifications}});
if ($missingGender) {
  print STDERR "Error: Pleace add missing info, and rerun. STOP.\n";
  exit $missingGender;
}


ProcessInfoSplitPhone({opts => \%opts, cfg => \%cfg, contacts => \%contacts});
ProcessInfoRemoveEmptyFields({opts => \%opts, cfg => \%cfg, contacts => \%contacts});

# ORG in exported vcards
my $org = defined $opts{org}?$opts{org}:"skfi:".$kl;

#StoreVcardsCombined({opts => \%opts, cfg => \%cfg, org => $org, modTime => \%modTime, contacts => \%contacts});
# Create four files separated on students and parents boy and girls (the students)
foreach my $srcGroup (qw(students parents)) {
  foreach my $gender (qw(b g)) {
    StoreVcardsSeparate({opts => \%opts, cfg => \%cfg, kl => $kl, org => $org, modTime => \%modTime, contacts => \%contacts, srcGroups => $srcGroup, gender => $gender});
  }
}

# Verify that all files are from the same class
my $numDifferentClasses = 1;
foreach my $f (keys %kl) {
  if ($kl ne $kl{$f}) {
    $numDifferentClasses++;
  }
}

if ($numDifferentClasses > 1) {
  print STDERR "Error: Files contains content from different classes:\n";
  foreach my $f (keys %kl) {
    print STDERR "- Class: $kl{$f}; File: $opts{in_file_base}$cfg{file_ending}{$f}.\n";
  }
}


# Get students and the order they are liste in
sub GetStudentNames {
  my $pms = pop @_;

  my $entry = 'student_list';

  my $filename = $$pms{opts}{in_file_base}.$$pms{cfg}{file_ending}{$entry};
  my $fh = IO::File->new($filename, "r");
  if (defined $fh) {
    my $active_section = 0;
  LINE:
    foreach my $l (<$fh>) {
      chomp $l;
      if ($l =~ m/^Navneliste for (.*)$/) {
        $active_section = 1;
	$$pms{kl}{$entry} = trim($1);
      }
      elsif ($active_section == 0) {
        next LINE;
      }
      elsif ($l =~ m/^\s*FORÆLDREINTRA/ && $active_section) {
	last LINE;
      }
      elsif ($l =~ m/^\s*$/) {
	# Drop empty/white space only line
      }
      else {
	$$pms{students}[scalar @{$$pms{students}}] = trim($l);
      }
    }
    undef $fh;
  }
  else {
    $$pms{kl}{$entry} = '?';
  }
  # ### pms.students: $$pms{students}
}


# Get student address and phones
sub GetStudentAdrPhone {
  my $pms = pop @_;

  my $entry = 'student_adr_phone';

  my $filename = $$pms{opts}{in_file_base}.$$pms{cfg}{file_ending}{$entry};
  my $fh = IO::File->new($filename, "r");
  if (defined $fh) {
    my $active_section = 0;
  LINE:
    foreach my $l (<$fh>) {
      chomp $l;
      if ($l =~ m/^\s*Adresse\- og telefonliste for (.*)\s*$/) {
        $active_section = 1;
	$$pms{kl}{$entry} = trim($1);
      }
      elsif ($active_section == 0) {
        next LINE;
      }
      elsif ($l =~ m/^\s*FORÆLDREINTRA/ && $active_section) {
	last LINE;
      }
      elsif ($l =~ m/^\s*$/) {
	# Drop empty/white space only line
      }
      elsif ($l =~ m/^ NAVN  	 ADRESSE 	 TELEFON 	 ELEVMOBIL  $/) {
	# Headerline
      }
      elsif ($l =~ m/^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$/) { # 4 fields with tabs between
	$$pms{contacts}{trim($1)}{student}{name} = trim($1); # Store student name twice
	$$pms{contacts}{trim($1)}{student}{adr} = trim($2);
	$$pms{contacts}{trim($1)}{student}{phone_home} = trim($3);
	$$pms{contacts}{trim($1)}{student}{phone_mob} = trim($4);
      }
      else {
	print "Error: GetStudentAdrPhone: Unknown line in $filename: '$l'\n";
      }
    }
    undef $fh;
  }
  else {
    $$pms{kl}{$entry} = '?';
  }
  # ### pms.contacts: $$pms{contacts}
}


# Get student email
sub GetStudentEmail {
  my $pms = pop @_;

  my $entry = 'student_email';

  my $filename = $$pms{opts}{in_file_base}.$$pms{cfg}{file_ending}{$entry};
  my $fh = IO::File->new($filename, "r");
  if (defined $fh) {
    my $active_section = 0;
  LINE:
    foreach my $l (<$fh>) {
      chomp $l;
      if ($l =~ m/^\s*Liste over (.*)'s e-mailadresser\s*$/) {
        $active_section = 1;
	$$pms{kl}{$entry} = trim($1);
      }
      elsif ($active_section == 0) {
        next LINE;
      }
      elsif ($l =~ m/^\s*FORÆLDREINTRA/ && $active_section) {
	last LINE;
      }
      elsif ($l =~ m/^\s*$/) {
	# Drop empty/white space only line
      }
      elsif ($l =~ m/^([^\t]*)\t([^\t]*)$/) { # 2 fields with tabs between
	$$pms{contacts}{trim($1)}{student}{email_work} = trim($2);
      }
      else {
	print "Error: GetStudentEmail: Unknown line in $filename: '$l'\n";
      }
    }
    undef $fh;
  }
  else {
    $$pms{kl}{$entry} = '?';
  }
  # ### pms.contacts: $$pms{contacts}
}


# Get student birthdays
sub GetStudentBirthday {
  my $pms = pop @_;

  my $entry = 'student_birthday';

  my $filename = $$pms{opts}{in_file_base}.$$pms{cfg}{file_ending}{$entry};
  my $fh = IO::File->new($filename, "r");
  if (defined $fh) {
    my $active_section = 0;
  LINE:
    foreach my $l (<$fh>) {
      chomp $l;
      if ($l =~ m/^\s*Oversigt over fødselsdage i (.*)\s*$/) {
        $active_section = 1;
	$$pms{kl}{$entry} = trim($1);
      }
      elsif ($active_section == 0) {
        next LINE;
      }
      elsif ($l =~ m/^\s*FORÆLDREINTRA/ && $active_section) {
	last LINE;
      }
      elsif ($l =~ m/^\s*$/) {
	# Drop empty/white space only line
      }
      elsif ($l =~ m/^ ELEVENS NAVN	 FØDSELSDAG 	  $/) {
	# Header line
      }
      elsif ($l =~ m/^([^\t]*)\t([^\t]*) Flag.*$/) { # 2 fields with tabs between + Flag.*
	$$pms{contacts}{trim($1)}{student}{birthday} = trim($2);
      }
      else {
	print "Error: GetStudentBirthday Unknown line in $filename: '$l'\n";
      }
    }
    undef $fh;
  }
  else {
    $$pms{kl}{$entry} = '?';
  }
  # ### pms.contacts: $$pms{contacts}
}


# Get parents contact info
sub GetParentsContactInfo {
  my $pms = pop @_;

  my $entry = 'parents_contact';

  my $filename = $$pms{opts}{in_file_base}.$$pms{cfg}{file_ending}{$entry};
  my $fh = IO::File->new($filename, "r");
  my $student = '?';
  my $infoFields;
  if (defined $fh) {
    my $active_section = 0;
  LINE:
    foreach my $l (<$fh>) {
      chomp $l;
      if ($l =~ m/^\s*Kontaktoplysninger i (.*)\s*$/) {
        $active_section = 1;
	$$pms{kl}{$entry} = trim($1);
      }
      elsif ($active_section == 0) {
        next LINE;
      }
      elsif ($l =~ m/^\s*FORÆLDREINTRA/ && $active_section) {
	last LINE;
      }
      elsif ($l =~ m/^\s*$/) {
	# Drop empty/white space only line
      }
      elsif ($l =~ m/^ELEV	KONTAKTPERSON 	ADRESSE 	FASTNET 	MOBIL 	ARBEJDE $/) {
	# Headerline
      }
      elsif ($l =~ m/^\ ([^\t]*)\t([^\t]*)(\t(.*))?$/) { # 1 Space, 2 or more (seen max 3) fields with tabs between: 1: student, 2:parent1, 3:Different
	$student = trim($1);
	$infoFields = 1;
	$$pms{contacts}{$student}{parent1}{name} = trim($2);
	if (defined($4) && $4 ne "") {
	  my @fields = split("\t", $4);
	  if (scalar @fields == 3) { # Special case - only seen parent1s contact info on this form - might fail - HACK
	    $$pms{contacts}{$student}{parent1}{adr} = trim($fields[0]);
	    $infoFields = 5;	# Parent1s phone - HACK
	    $$pms{contacts}{$student}{parent1}{phone_home} = trim($fields[1]);
	    $$pms{contacts}{$student}{parent1}{phone_mob} = trim($fields[2]);
	  }
	  else {		# General case
	    foreach my $f (@fields) {
	      $infoFields++;
	      $$pms{contacts}{$student}{"contact$infoFields"} = trim($f);
	    }
	  }
	}
      }
      elsif ($l =~ m/^([^\t]*)\t([^\t]*)$/) { # 2 fields with tabs between
	$infoFields++;
	$$pms{contacts}{$student}{"contact$infoFields"} = trim($1);
	$infoFields++;
	$$pms{contacts}{$student}{"contact$infoFields"} = trim($2);
      }
      elsif ($l =~ m/^([^\t]*)$/) { # 1 fields with optional tab before
	$infoFields++;
	$$pms{contacts}{$student}{"contact$infoFields"} = trim($1);
      }
      else {
	print "Error: GetParentsContactInfo: Unknown line in $filename: '$l'\n";
      }
    }
    undef $fh;

    # Fix contact info
    foreach my $c (keys $$pms{contacts}) {
      if (defined $$pms{contacts}{$c}{contact7}) { # Assuming 2 parents with all or partial info (except work phone)
	# Assumes contact2 is parent2s name if non-empty and use + remove if seems ok
	if ($$pms{contacts}{$c}{contact2} !~ m/^$/) { # !Empty field
	  $$pms{contacts}{$c}{parent2}{name} = $$pms{contacts}{$c}{contact2};
	}
	delete $$pms{contacts}{$c}{contact2};

	# Parsing contact3 and use + remove if seems ok
	if ($$pms{contacts}{$c}{contact3} =~ m/^(.*?), ([0-9]{4} .*)$/) { # Contains 4 digit postal code
	  $$pms{contacts}{$c}{parent1}{adr} = $1.", ".$2;
	  delete $$pms{contacts}{$c}{contact3};
	}
	elsif ($$pms{contacts}{$c}{contact3} =~ m/^([0-9]{4} .*)$/) { # No address except Contains 4 digit postal code + town
	  $$pms{contacts}{$c}{parent1}{adr} = $1;
	  delete $$pms{contacts}{$c}{contact3};
	}
	elsif ($$pms{contacts}{$c}{contact3} =~ m/^$/) { # Empty field
	  delete $$pms{contacts}{$c}{contact3};
	}
	else {
	  print STDERR "Warning: Expecting address for parent1 to $c, got: '$$pms{contacts}{$c}{contact3}' (no postal code)\n";
	}

	# Parsing contact4 and use + remove if seems ok
	if ($$pms{contacts}{$c}{contact4} =~ m/^(.*?), ([0-9]{4} .*)$/) { # Contains 4 digit postal code
	  $$pms{contacts}{$c}{parent2}{adr} = $1.", ".$2;
	  delete $$pms{contacts}{$c}{contact4};
	}
	elsif ($$pms{contacts}{$c}{contact4} =~ m/^([0-9]{4} .*)$/) { # No address except Contains 4 digit postal code + town
	  $$pms{contacts}{$c}{parent2}{adr} = $1;
	  delete $$pms{contacts}{$c}{contact4};
	}
	elsif ($$pms{contacts}{$c}{contact4} =~ m/^$/) { # Empty field
	  delete $$pms{contacts}{$c}{contact4};
	}
	else {
	  print STDERR "Warning: Expecting address for parent2 to $c, got: '$$pms{contacts}{$c}{contact4}' (no postal code)\n";
	}

        $$pms{contacts}{$c}{parent1}{phone_home} = $$pms{contacts}{$c}{contact5};
        delete $$pms{contacts}{$c}{contact5};

        $$pms{contacts}{$c}{parent2}{phone_home}  = $$pms{contacts}{$c}{contact6};
        delete $$pms{contacts}{$c}{contact6};

        $$pms{contacts}{$c}{parent1}{phone_mob} = $$pms{contacts}{$c}{contact7};
        delete $$pms{contacts}{$c}{contact7};

	if (defined $$pms{contacts}{$c}{contact8}) {
          $$pms{contacts}{$c}{parent2}{phone_mob}  = $$pms{contacts}{$c}{contact8};
          delete $$pms{contacts}{$c}{contact8};
	}
        delete $$pms{contacts}{$c}{contact9} if defined $$pms{contacts}{$c}{contact9} && $$pms{contacts}{$c}{contact9} eq ''; # Empty work phone?
      }

      # Delete trailing empty contact fields
    DELETE_EMPTY_CONTACTS:
      for (my $i = 6; $i >= 2; $i--) {
	if (defined $$pms{contacts}{$c}{"contact$i"}) {
	  if ($$pms{contacts}{$c}{"contact$i"} eq '') {
	    delete $$pms{contacts}{$c}{"contact$i"};
	  }
	  else {
	    last DELETE_EMPTY_CONTACTS;
	  }
	}
      }
    }
  }
  else {
    $$pms{kl}{$entry} = '?';
  }
  # ### pms.contacts: $$pms{contacts}
}


# Get parents email
sub GetParentsEmail {
  my $pms = pop @_;

  my $entry = 'parents_email';

  my $filename = $$pms{opts}{in_file_base}.$$pms{cfg}{file_ending}{$entry};
  my $fh = IO::File->new($filename, "r");
  if (defined $fh) {
    # The next parameters must be reset to initial value when a new student name is found
    my $student = '';
    my $lastFieldWasEmail = 1; # 1: Email, 0=Name - After email-addresses a new student name comes
    # Are parent1s and parent2s names found? - Store in array in the order they have been found
    my @parents_found = ();	# Element values: parent1, parent2
    my $active_section = 0;
  FIELD:
    foreach my $f (split("\t", join("\t", <$fh>))) {
      chomp $f;
      if ($f =~ m/^Forældrenes e-mailadresser i (.*)$/) {
        $active_section = 1;
	$$pms{kl}{$entry} = trim($1);
      }
      elsif ($active_section == 0) {
        next FIELD;
      }
      elsif ($f =~ m/^(ELEV|KONTAKTPERSON|E\-MAILADRESSE)/) {
	# Header-fields
      }
      elsif ($f =~ m/^\s*$/) {
	# Drop empty/white space only line
      }
      elsif ($f =~ m/^FORÆLDREINTRA/ && $active_section) {
	# Stop processing - footer
	last FIELD;
      }
      elsif ($student ne '' && defined $$pms{contacts}{$student}{parent1} && defined $$pms{contacts}{$student}{parent1}{name} && ($f eq $$pms{contacts}{$student}{parent1}{name})) { # Parent1s name
	$parents_found[scalar @parents_found] = 'parent1';
	$lastFieldWasEmail = 0;
      }
      elsif ($student ne '' && defined $$pms{contacts}{$student}{parent2} && defined $$pms{contacts}{$student}{parent2}{name} && ($f eq $$pms{contacts}{$student}{parent2}{name})) { # Parent2s name
	$parents_found[scalar @parents_found] = 'parent2';
	$lastFieldWasEmail = 0;
      }
      elsif (defined $$pms{contacts}{$f}) { # Parse new student
	$student = $f;
	@parents_found = ();
	$lastFieldWasEmail = 0;
      }
      elsif ($f =~ m/\@/) {	# An email address
	if (scalar(@parents_found) > 0) { # Still parent email addresses to get (shifted of from @parents_found when email found
	  my $parent = shift @parents_found;
	  $$pms{contacts}{$student}{$parent}{email} = trim($f);
	}
      }
      else {
	print "Error: GetParentsEmail: Unknown field in $filename: '$f'\n";
      }
    }
    undef $fh;
  }
  else {
    $$pms{kl}{$entry} = '?';
  }
  # ### pms.contacts: $$pms{contacts}
}


# Modify contacts with data from another file, e.g. common or private data not read via Forældreintra Kontakt lists
sub ApplyContactModifications {
  my $pms = pop @_;
  if (-e $$pms{modFile}) {
    my $mod = scalar Load(scalar read_file($$pms{modFile}, binmode => ':raw'));

    while (my ($student, $studentData) = each %{$mod}) {
    PERSON:
      foreach my $e (qw(student parent1 parent2)) {
    	if (not defined $$studentData{$e}) {
    	  next PERSON;
    	}
    	my %c = %{$$studentData{$e}};
    	foreach my $f (keys %c) {
    	  my $r = ref $c{$f};
    	  if ($r =~ /^$/) {
    	    $$pms{contacts}{"$student"}{$e}{$f} = $c{$f} if defined $c{$f};
    	  }
    	  else {
    	    print "Error: Ignoring private data in modification variable{'<kl>'}{'$student'}{$e}{$f}\n";
    	  }
    	}
      }
    }

  }
}

sub RequestMissingGenerInformation {
  my $pms = pop @_;

  my $missing = 0;
  my $file_header_example = "# -*-yaml-*-

# ## Help
# gender: Boy=b; Girl=g
# Optional add other modifications, like nickname: Nick N, where nickname is listed just below gender, with same indention!
# Information for the parents are stored below parent1 and parent2 (parent1 is the first(upper), most often the mother on Forældreintra)
# Fields are:
# - adr
# - birthday	Normally only used for the students, but can be used for parents as well
# - email 	Normally used for parents
# - email_work	Normally used for students
# - gender	Normally only used for the students, but can be used for parents as well
# - name
# - nickname	Primary for students, e.g. Nick N and Nick M for Nick Nielsen and Nick Mortensen
# - phone_home
# - phone_mob
#
# Example:
# '# ' is just to mark the next lines as comment.
# Peter J. Jensen:
#   student:
#     gender: b
#     nickname: Peter J
#   parent1:
#   parent2:
#

";

  my $msg = '';
  foreach my $student (sort(keys %{$$pms{contacts}})) {
  PERSON:
    # Check gender
    if (not defined $$pms{contacts}{$student}{student}{gender}) { # Missing gender info
      if (getGender($student) eq 'b|g') { # Not regex match, b|g is returned if b or g
        $msg .= "$student:\n  student:\n    gender: b|g\n    nickname:\n";
        $missing++;
      }
      else {
        $$pms{contacts}{$student}{student}{gender} = getGender($student);
        $msg .= "$student:\n  student:\n    #gender: ".getGender($student)."\n    nickname:\n";
      }
    }
    elsif ($$pms{contacts}{$student}{student}{gender} !~ /^[bg]$/) {
      print STDERR "Error: Wrong gender for $student: $$pms{contacts}{$student}{student}{gender}. Place fix it in $$pms{commonDataFile}.\n";
    }
  }

  if (!-e $$pms{commonDataFile}) {
    my $fh = IO::File->new($$pms{commonDataFile}, "w");
    if (defined $fh) {
      # File doesent exist, but openend for write
      print $fh $file_header_example.$msg;
      undef $fh;
      return $missing;
    }
  }
  elsif ($missing || $$pms{verbose}) {
    print STDERR "Pleace add the following content to $$pms{commonDataFile} (create the file if missing)\n - and change b|g to either b or g:\n";
    print STDERR $file_header_example.$msg;
  }
  return $missing;
}

# Process contact info - split phone info, only valid delimiter is - (input check in Forældreintra)
sub ProcessInfoSplitPhone {
  my $pms = pop @_;

  while (my ($k, $v) = each %{$$pms{contacts}}) {
    # Process a contact
    foreach my $person (qw(student parent1 parent2)) {
      if (defined $$v{$person}) {
	foreach my $e (keys $$v{$person}) {
	  if ($e =~ m/^phone_/) {
	    if ($$v{$person}{$e} =~ m/^([0-9]+)\-([0-9]+)$/) {
              $$v{$person}{$e} = $1;
              $$v{$person}{$e.'2'} = $2;
	    }
	  }
	}
      }
    }
  }
}

# Process contact info - Remove empty fields
sub ProcessInfoRemoveEmptyFields {
  my $pms = pop @_;

  while (my ($k, $v) = each %{$$pms{contacts}}) {
    # Process a contact
    ## Remove empty fields
    foreach my $person (qw(student parent1 parent2)) {
      if (defined $$v{$person}) {
	foreach my $e (keys $$v{$person}) {
	  if ($$v{$person}{$e} eq '') {
	    delete $$v{$person}{$e};
	  }
	}
      }
    }
  }
}

sub ProcessInfoCombine {
  my $pms = pop @_;

  while (my ($student, $v) = each %{$$pms{contacts}}) {
    ## Store #parents there are contact info for
    $$v{proc}{num_parents} = 0;
    $$v{proc}{num_parents}++ if defined $$v{parent1};
    $$v{proc}{num_parents}++ if defined $$v{parent2};


    ## Reduce num addresses, email
    foreach my $fieldType (qw(adr email phone)) {
      my $eSrc;
      # Optional sub-types
      my @subtype;
      $subtype[0] = '';		# Default: No subtype
      @subtype = qw(_home _mob) if ($fieldType eq 'phone');
      ## Reorganize
      foreach my $sub (@subtype) {
	foreach my $e (qw(student parent1 parent2)) {
	  my $fSub = $fieldType.$sub;
	  if (defined $$v{$e} && defined $$v{$e}{$fSub}) {
	    $$v{proc}{$fieldType}{$$v{$e}{$fSub}}{$e.$sub} = 1; # Store address in contacts{student}{$fieldType}{<Data content value>}{student|parent1|parent2 + optional _home|_mob} = 1
	    #delete $$v{$e}{$fSub}; # Remove src
	  }
	}
      }
    }

    # Create {proc}{common}{adr} if only one adr is listed
    my ($adr_key, $adr_detils) = each %{$$v{proc}{adr}};
    if (keys %{$$v{proc}{adr}} == 1) {
      $$v{proc}{common}{adr} = $adr_key;
    }
  }
}

sub StoreVcardsCombined {
  my $pms = pop @_;

  ProcessInfoCombine($pms);

  while (my ($student, $v) = each %{$$pms{contacts}}) {
    # ### student: $student
    # ### v: $v
  }
}

sub StoreVcardsSeparate {
  my $pms = pop @_;

  my @srcs;			# Wihch groups choose
  if ($$pms{srcGroups} eq 'all') {
    @srcs = qw(student parent1 parent2)
  }
  elsif ($$pms{srcGroups} eq 'students') {
    @srcs = qw(student)
  }
  elsif ($$pms{srcGroups} eq 'parents') {
    @srcs = qw(parent1 parent2)
  }
  else {
    die "Error: {srcGroups} must be one of all, students, parents\n";
  }

  my $vcard = '';
 STUDENT:
  while (my ($student, $studentData) = each %{$$pms{contacts}}) {
    if ($$pms{gender} =~ m/^[bg]$/ && $$studentData{student}{gender} ne $$pms{gender}) {
      next STUDENT;		# Not processing this gender now
    }

  PERSON:
    foreach my $e (@srcs) {
      if (not defined $$studentData{$e}) {
	next PERSON;
      }
      my $itemCnt = 0;
      my %c = %{$$studentData{$e}};
      $vcard .= <<'EOSinit';
BEGIN:VCARD
VERSION:4.0
EOSinit
      my $student_uid = $student;
      $student_uid =~ tr/a-zA-Z//dc;
      $student_uid = "skfi-adr-".$$pms{kl}."-".$student_uid;
      $vcard .= "UID:urn:uuid:".$student_uid.'-'.$e."\n";
      if ($e eq 'student') {
	$vcard .= 'N:'.$c{name}.'
N:'.SplitName(';', $c{name}).';;'."\n";
      }
      else { # Parent - Prefix name with <student nickname or student first name>:
	my $studentNick = GetNickOrFirstName({contact => $$studentData{student}}); # Prefix: student Nick or First name
	$vcard .= 'FN;PID=1.1:'.$studentNick.': '.$c{name}.'
N:'.SplitName(';', $c{name}, $studentNick.': ').';;'."\n";
      }
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'NICKNAME;PID=1.1:', post => '', field => 'nickname'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'EMAIL;PID=1.1;TYPE=WORK:', post => '', field => 'email_work'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'EMAIL;PID=2.1;TYPE=HOME:', post => '', field => 'email'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'ADR;PID=1.1;TYPE=HOME:', post => '', field => 'adr', type => 'adr'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'TEL;PID=1.1;TYPE=CELL:', post => '', field => 'phone_mob', type => 'phone'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'TEL;PID=2.1;TYPE=HOME:', post => '', field => 'phone_home', type => 'phone'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'TEL;PID=3.1;TYPE=CELL:', post => '', field => 'phone_mob2', type => 'phone'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'TEL;PID=4.1;TYPE=HOME:', post => '', field => 'phone_home2', type => 'phone'});
      $vcard .= VcardAddFieldOptional({contact => \%c, pre => 'BDAY:', post => '', field => 'birthday', type => 'date'});
      $vcard .= 'ORG;PID=1.1:'.$$pms{org}."\n" if defined $$pms{org};
      # Insert relations (parent<->child)
      if ($e eq 'student') {
	for (my $i = 1; $i <= 2; $i++) {
	  if (defined $$studentData{'parent'.$i} && defined $$studentData{'parent'.$i}{name}) {
	    $itemCnt++;
	    $vcard .= "RELATED;PID=".$itemCnt.".1;TYPE=parent:urn:uuid:".$student_uid."-parent".$itemCnt."\n";
            $vcard .= 'item'.$itemCnt.'.X-ABRELATEDNAMES:'.$$studentData{'parent'.$i}{name}."\n";
	    $vcard .= 'item'.$itemCnt.'.X-ABLabel:_$!<Parent>!$_'."\n"; # Instead of Parent Mother and Father is legal, but parent1 and parent2 is not always mother and father in that order
	  }
	}
      }
      else {
	# Parents - insert ralation to child/student
	$itemCnt++;
        $vcard .= "RELATED;PID=".$itemCnt.".1;TYPE=child:urn:uuid:".$student_uid."-student\n";
	$vcard .= 'item'.$itemCnt.'.X-ABRELATEDNAMES:'.$$studentData{student}{name}."\n";
	$vcard .= 'item'.$itemCnt.'.X-ABLabel:_$!<Child>!$_'."\n";
      }

      $vcard .= "SOURCE;PID=1.1:skfi-adr\n";
      $vcard .= "REV:".POSIX::strftime('%Y%m%dT%H%M%S%z', localtime($$pms{modTime}{max}))."\n";
      $vcard .= 'NOTE:';
      # Write note about wher the data comes from
      $vcard .= 'Data hentet fra forældreintra d. ';
      $vcard .= POSIX::strftime('%Y-%m-%d', localtime($$pms{modTime}{min}));
      if (POSIX::strftime('%Y-%m-%d', localtime($$pms{modTime}{min})) eq
	  POSIX::strftime('%Y-%m-%d', localtime($$pms{modTime}{max}))) {
	$vcard .= '.';
      }
      else {
	$vcard .= ' - ' .POSIX::strftime('%Y-%m-%d', localtime($$pms{modTime}{max})) .'.';
      }
      $vcard .= "\n";		# End of NOTE
      $vcard .= "CLIENTPIDMAP:1;urn:uuid:".$client_uuid."\n";
      $vcard .= 'END:VCARD'."\n";

      #$vcard .= VcardAddJpg({jpg => '<path to jpg>.jpg'});
    }
  }
  # ### vcard: $vcard
  my $fileGenderInfoString = '';
  if ($$pms{gender} eq 'b') {
    $fileGenderInfoString = '.boys';
  }
  elsif ($$pms{gender} eq 'g') {
    $fileGenderInfoString = '.girls';
  }
  my $filename = $$pms{opts}{out_file_base}.$fileGenderInfoString.'.'.$$pms{srcGroups}.'.vcf';
  my $fh = IO::File->new($filename, "w");
  if (defined $fh) {
    print $fh $vcard;
    undef $fh;
  }
  else {
    print STDERR "Error: Could not open $filename for writing: $?\n";
    return 1;
  }

}

sub VcardAddFieldOptional {
  my $pms = pop @_;

  if (defined $$pms{contact}{$$pms{field}}) {
    my $data = $$pms{contact}{$$pms{field}};
    # Optionally reformat data, depending on type
    if (defined $$pms{type}) {
      if ($$pms{type} eq 'adr') {
	if ($data =~ m/^(.*?), ([0-9]{4}) (.*)$/) {
	  $data = ';;'.$1.';'.$3.';;'.$2;
	}
	# Else leave with src. formatting, might be ok.
      }
      elsif ($$pms{type} eq 'phone') {
	if ($data =~ m/^((00)?45)?([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})$/) {
	  $data = "$3 $4 $5 $6";
	}
	# Else leave with src. formatting, might be ok.
      }
      elsif ($$pms{type} eq 'date') {
	if ($data =~ m/^([0-9]{2})-([0-9]{2})-([0-9]{4})$/) {
	  $data = "$3-$2-$1";
	}
	# Else leave with src. formatting, might be ok.
      }
    }
    return $$pms{pre}.$data.$$pms{post}."\n";
  }
  return '';
}

sub GetNickOrFirstName {
  my $pms = pop @_;

  if (defined $$pms{contact}{nickname}) {
    return $$pms{contact}{nickname};
  }
  else {
    $$pms{contact}{name} =~ m/^([^\s]+)/;
    return $1;
  }
}

sub VcardAddJpg {
  my $pms = pop @_;

  my $fhImg = IO::File->new($$pms{jpg}, "r");
  my $ret = '';
  if (defined $fhImg) {
    my $raw_string = do{ local $/ = undef; <$fhImg>; };
    undef $fhImg;
    $ret .= 'PHOTO;TYPE=JPEG;ENCODING=BASE64:'."\n ";
    # Requires "use MIME::Base64;" un-commented above.
    $ret .= encode_base64($raw_string, "\n ");
    chop $ret;			# Remove last space
    return $ret;
  }
}

sub SplitName {
  my $split = shift @_;
  my $name = shift @_;
  my $prefix = shift @_;

  $prefix = '' if !$prefix;

  if ($name =~ m/^([^\s]+)(\ (.*?))?\ ([^\s]+)/) {
    my $ret = "$4$split$prefix$1$split";
    if (defined $3) {
      $ret .= $3;
    }
    return $ret;
  }
  else {
    return $name.$split.$split;
  }
}

sub getGenderListFromFiles {
  my $genderRef = shift @_;
  my $gender = shift @_;
  my $file = shift @_;

  my %genders;
  my $fh = IO::File->new($file, "r") || die("Can't open '$file'\n");
  foreach my $l (<$fh>) {
    chomp $l;
    if ($l !~ m/^$/) {
      $$genderRef{trim($l)} = $gender;
    }
  }
  undef $fh;
}

sub getGender {
  my $name = join(' ', @_);

  my $name1 = $name;
  # Try match name until first space
  $name1 =~ s/^([^\ ]+).*$/$1/;
  if (defined $genders{$name1}) {
    return $genders{$name1};
  }
  # Try match name until first - or space
  $name1 =~ s/^([^\-\ ]+).*$/$1/;
  if (defined $genders{$name1}) {
    return $genders{$name1};
  }

  # No match
  return 'b|g';
}


# ######################################################################
# General helper functions
# ######################################################################

# Trim leading and trailing white space
sub trim {
  return $_[0] =~ s/^\s+|\s+$//rg;
}
