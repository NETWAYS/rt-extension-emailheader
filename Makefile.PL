use inc::Module::Install;

RTx     'RT-Extension-EmailHeader';
license 'gpl_2';
repository 'https://github.com/NETWAYS/rt-extension-emailheader';
readme_from 'lib/RT/Extension/EmailHeader.pm';

requires_rt '4.2';

sign;
WriteAll;
