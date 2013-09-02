#!/usr/bin/env perl

use inc::Module::Install;

name  'Logster';
author 'John Toomey <john.toomey@tradingtechnologies.com>';
all_from 'lib/Logster.pm';
include 'Module::AutoInstall';
license 'GPLv2';

requires 'threads'           => '1.31';
requires 'threads::shared'   => '1.01';
requires 'Thread::Queue'     => '2.00';
requires 'Thread::Semaphore' => '2.01';
requires 'Fcntl'             => '1.05';
requires 'Hash::Merge'       => '0.12';
requires 'Time::HiRes'       => '1.86';
requires 'Term::ANSIColor'   => '1.10';
requires 'Time::Local'       => '1.11';

auto_install;
WriteAll;
