# SUSE's openQA tests
#
# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: zypper
# Summary: test for 'zypper lifecycle'
# - Run "zypper lifecycle" and parse its output for some header and links
# - Runs a series of checks to determine a suitable package to validade
# lifecycle, else hardcode to "sles-release"
# - Backup original lifecycle data files (if exists)
# (/var/lib/lifecycle/data/$prod.lifecycle) and create a new one with
# "2020-02-03" as date and sles-release as package
# - Check zypper lifecycle sles-release output
# - Check zypper lifecycle sles-release --date 2020-02-04
# - Check zypper lifecycle sles-release --date 2020-02-02
# - Delete lifecycle data previously created
# - Get product EOL by parsing /etc/products.d/$product.prod
# - Check if product EOL matches test package EOL
# - Restore original lifecycle data
# - Check output of "zypper lifecycle --help"
# - Check return of "zypper lifecycle --days 0"
# - Check output of "zypper lifecycle --date $(date --iso-8601)"
# - Check output of "zypper lifecycle --days 9999"
# Maintainer: QE Core <qe-core@suse.de>
# Tags: fate#320597

use base "consoletest";
use strict;
use warnings;
use testapi;
use utils;
use version_utils qw(is_sle is_jeos is_upgrade);
use Utils::Architectures;
use serial_terminal qw(select_serial_terminal select_user_serial_terminal);
use registration qw(add_suseconnect_product get_addon_fullname);

our $date_re = qr/[0-9]{4}-[0-9]{2}-[0-9]{2}/;

sub lifecycle_output_check {
    my $output = shift;
    if (is_sle('=15-sp3') && $output =~ /Python 2 Module.*2023-12-3(0|1)/) {
        record_info 'poo#129026';
        return;
    }
    if (get_var('SCC_REGCODE_LTSS') || get_var('SCC_REGCODE_LTSS_ES') || get_var('SCC_REGCODE_LTSS_TD')) {
        if ($output =~ /No products.*before/) {
            record_info('Softfail', "poo#95593 https://jira.suse.com/browse/MSC-70");
            return;
        }
        die "SUSE Linux Enterprise Server is end of support\nOutput: '$output'" unless $output =~ /SUSE Linux Enterprise Server/;
    }
    else {
        die "All products should be supported as of today\nOutput: '$output'" unless $output =~ /No products.*before/;
    }
}

sub run {
    diag('fate#320597: Introduce \'zypper lifecycle\' to provide information about life cycle of individual products and packages');

    select_serial_terminal;

    if (get_var('SCC_REGCODE_LIVE')) {
        # https://progress.opensuse.org/issues/133514
        my $live_reg_code = get_var('SCC_REGCODE_LIVE');
        add_suseconnect_product(get_addon_fullname('live'), undef, undef, "-r $live_reg_code");
    }

    # First we'd make sure that we have a clean zypper cache env and all dirs have
    # 0755 and all files have 0644 pemmission.
    # For some reason the system will change the permission on /var/cache/zypp/{solv,raw}
    # files. this cause the zypper lifecycle failed when building cache for non-root user.
    assert_script_run('chmod -R u+rwX,og+rX /var/cache/zypp');
    zypper_call('in curl') if (script_run('rpm -qi curl') == 1);
    # force reinstall release notes, package must not come from expected SLE-Product repo e.g. GMC
    zypper_call('in -f release-notes*');
    zypper_call('in zypper-lifecycle-plugin') if (is_sle('>=16'));

    select_user_serial_terminal;
    my $overview = script_output('zypper lifecycle', 600);
    die "Missing header line:\nOutput: '$overview'" unless $overview =~ /Product end of support/;
    die "Missing link to lifecycle page:\nOutput: '$overview'"
      if $overview =~ /n\/a/ && $overview !~ qr{\*\) See https://www.suse.com/lifecycle for latest information};
    # Compare to test data from
    # https://github.com/nadvornik/zypper-lifecycle/blob/master/test-data/SLES.lifecycle
    # from https://fate.suse.com/320597
    # 1. verify that "zypper lifecycle" shows correct eol dates for installed
    # products (this tests also fate#320699)
    #
    # 3. verify that "zypper lifecycle" shows correct package eol based on the
    # data from step 2
    my ($base_repos, $package);
    my $prod = script_output 'basename `readlink /etc/products.d/baseproduct ` .prod';
    # select a package suitable for the following test
    # the package must be installed from base product repo
    my $output = script_output 'echo $(zypper -n -x se -i -t product -s ' . $prod . ')', 300;
    # Parse base repositories
    if (my @repos = $output =~ /repository="([^"]+)"/g) {
        $base_repos = join(" ", @repos);
    }

    die "Got malformed repo list:\nOutput: '$output'" unless $base_repos;

    if (is_sle('>=16')) {
        # For sle16, it has only one repository, see https://progress.opensuse.org/issues/185221
        $output = script_output('echo $(zypper -n -x se -t package -i -s | grep name= | head -n 1 )', 600);
    }
    else {
        $output = script_output 'echo $(for repo in ' . $base_repos . ' ; do zypper -n -x se -t package -i -s -r $repo ; done | grep name= | head -n 1 )', 600;
    }

    # Parse package name
    if ($output =~ /name="(?<package>[^"]+)"/) {
        $package = $+{package};
    }
    # For JeOS build testing we are always using the latest repositories, because
    # JeOS images are build with a *different* build number to SLES/Leap. It seems
    # that SLES repositories are not populated with packages for several hours
    # (I have seen the test pass after 14 hours from the image creation), and actually
    # no package in the image comes from any repository - it's from the image. So we
    # hard-code 'sles-release' package, and it... works. Somehow.
    if (!$package && is_jeos) {
        record_info 'Workaround', "Hardcoding 'sles-release' package for lifecycle check", result => 'softfail';
        $package = 'sles-release';
    }
    die "No suitable package found. Script output:\nOutput: '$output'" unless $package;

    my $testdate = '2620-02-03';
    my $testdate_after = '2620-02-04';
    my $testdate_before = '2620-02-02';
    # backup and create our lifecycle data with known content
    select_serial_terminal;
    my $backup = <<"EOF";
if [ -f /var/lib/lifecycle/data/$prod.lifecycle ] ; then
    mv /var/lib/lifecycle/data/$prod.lifecycle /var/lib/lifecycle/data/$prod.lifecycle.orig
fi
mkdir -p /var/lib/lifecycle/data
echo '$package, *, $testdate' > /var/lib/lifecycle/data/$prod.lifecycle
EOF
    script_output $backup;
    # verify eol from lifecycle data
    select_user_serial_terminal;
    $output = script_output "zypper lifecycle $package", 300;
    die "$package lifecycle entry incorrect:\nOutput: '$output'" unless $output =~ /$package(-\S+)?\s+$testdate/;

    # test that the package is reported if we query the date after
    $output = script_output "zypper lifecycle --date $testdate_after", 300;
    die "$package not reported for date $testdate_after:\nOutput: '$output'" unless $output =~ /$package(-\S+)?\s+$testdate/;

    # test that the package is not reported if we query the date before
    # report can be empty - exit code 1 is allowed
    $output = script_output "zypper lifecycle --date $testdate_before || test \$? -le 1", 300;
    die "$package reported for date $testdate_before:\nOutput: '$output'" if $output =~ /$package(-\S+)?\s+$testdate/;

    # delete lifecycle data - package eol should default to product eol
    select_serial_terminal;
    assert_script_run "rm -f /var/lib/lifecycle/data/$prod.lifecycle";

    # get product eol
    my $product_file = "/etc/products.d/$prod.prod";
    my $product_name = script_output "grep '<summary>' $product_file";
    $product_name =~ s/.*<summary>([^<]*)<\/summary>.*/$1/s || die "no product name found in $product_file";
    record_info('Product found', "Product found in overview: '$product_name'");

    my $product_eol;
    for my $l (split /\n/, $overview) {
        if ($l =~ /^(?<!Codestream:)\s+(Product: )?$product_name\s*(\S*)/) {
            $product_eol = $2;
            last;
        }
    }
    die "baseproduct eol not found in overview\nOutput: '$product_name'" unless $product_eol;

    select_user_serial_terminal;
    # verify that package eol defaults to product eol
    # dash is accepted in prod EOL, despite it does not match zypper lifecycle, see poo#126794
    $output = script_output "zypper lifecycle $package", 300;
    if (is_sle('=12-sp5') && $output =~ /ImageMagick-config-6-SUSE.*n\/a\*/) {
        record_info 'bsc#1231125', 'poo#167602';
        return;
    }
    unless ($output =~ /$package(-\S+)?\s+($product_eol|-$)/) {
        die "$package lifecycle entry incorrect:\nOutput: '$output', expected: '/$package-\\S+\\s+$product_eol'";
    }

    # restore original data, if any
    select_serial_terminal;
    my $restore = <<"EOF";
if [ -f /var/lib/lifecycle/data/$prod.lifecycle.orig ] ; then
    mv /var/lib/lifecycle/data/$prod.lifecycle.orig /var/lib/lifecycle/data/$prod.lifecycle
fi
EOF
    script_output $restore;
    select_user_serial_terminal;
    # 4. verify that "zypper lifecycle --days N" and "zypper lifecycle --date
    # D" shows correct results
    assert_script_run 'zypper lifecycle --help';

    # report should be empty - exit code 1 is expected
    # but it can show maintenance updates released during last few minutes
    $output = script_output 'zypper lifecycle --days 0 || test $? -le 1', 300;
    lifecycle_output_check($output);

    # report should be empty - exit code 1 is expected
    # but it can show maintenance updates released during last few minutes
    $output = script_output 'zypper lifecycle --date $(date --iso-8601) || test $? -le 1', 300;
    lifecycle_output_check($output);

    $output = script_output 'zypper lifecycle --days 9999', 300;
    die "Product 'end of support' line not found\nOutput: '$output'" unless $output =~ /Product end of support before/;
    die "Current product should not be supported anymore\nOutput: '$output'" unless $output =~ /$product_name\s+$product_eol/;
}

sub test_flags {
    return {milestone => 1, fatal => 0};
}

sub post_fail_hook {
    my ($self) = shift;
    $self->SUPER::post_fail_hook;
    # Additionally collect executed scripts
    assert_script_run 'tar -cf /tmp/script_output.tgz /tmp/*.sh';
    upload_logs '/tmp/script_output.tgz';
}

1;
