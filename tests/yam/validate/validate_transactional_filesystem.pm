# SUSE's openQA tests
#
# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: FSFAP


# Summary: Validate behaviour of transactional filesystem
# Maintainer: QE Installation and Migration (QE Iam) <none@suse.de>

use Mojo::Base 'consoletest';
use testapi;

sub run {
    select_console 'root-console';

    die 'Should have failed' unless script_run('touch /should_fail');
    assert_script_run "touch /etc/should_succeed";
    assert_script_run "touch /var/log/should_succeed";

    validate_script_output("transactional-update -h", qr /Applies package updates to a new snapshot/,
        fail_message => 'transactional-update -h seems to have problems.');
    die 'zypper should have complained' unless script_run('zypper in patterns-base-transactional_base');
}

1;
