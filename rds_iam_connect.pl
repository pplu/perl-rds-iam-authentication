#!/usr/bin/env perl

use strict;
use warnings;
use DBI;
use v5.10;
use DateTime;
use Digest::SHA qw/sha256_hex hmac_sha256 hmac_sha256_hex/;

sub usage {
  say "Connects to the database with the IAM credentials";
  say "Usage $0 host user access_key secret_key";
}

my $host = $ARGV[0] or usage;
my $user = $ARGV[1] or usage;
my $ak   = $ARGV[2] or usage;
my $sk   = $ARGV[3] or usage;

my $region = 'eu-west-1';
my $service = 'rds-db';
my $port = 3306;

# Start the signing process from https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.Connecting.Java.html
# Code adapted from "Manually constructing an Authentication Token".

my $now = DateTime->now;

my $date = $now->ymd('');
my $dateTimeStamp = $now->ymd('') . 'T' . $now->hms('') . 'Z';
my $expirySeconds = 900;

my $requestWithoutSignature;

sub createCanonicalString {
  my ($user, $accessKey, $date, $dateTime, $region, $expiryPeriod, $hostName, $port) = @_;
  my @qParams = (
    [ 'Action', 'connect' ],
    [ 'DBUser', $user ],
    [ 'X-Amz-Algorithm', 'AWS4-HMAC-SHA256' ],
    [ 'X-Amz-Credential', $accessKey . "%2F" . $date . "%2F" . $region . "%2F" . $service . "%2Faws4_request" ],
    [ 'X-Amz-Date', $dateTime ],
    [ 'X-Amz-Expires', 900 ],
    [ 'X-Amz-SignedHeaders'  => 'host' ],
  );
  my $canonicalQString = join '&', map { $_->[0] . '=' . $_->[1] } @qParams;
  my $canonicalHeaders = "host:" . $hostName . ":" . $port . "\n";
  $requestWithoutSignature = $hostName . ":" . $port . "/?" . $canonicalQString;
  
  my $hashedPayload = sha256_hex('');
  return join "\n", "GET", "/", $canonicalQString, $canonicalHeaders, 'host', $hashedPayload;
}

sub createStringToSign {
  my ($dateTime, $canonicalRequest, $accessKey, $date, $region) = @_;
  my $credentialScope = join '/', $date, $region, $service, 'aws4_request';
  return join "\n", "AWS4-HMAC-SHA256", $dateTime, $credentialScope, sha256_hex($canonicalRequest);
}

sub calculateSignature {
  my ($stringToSign, $signingKey) = @_;
  return hmac_sha256_hex($stringToSign, $signingKey);
}

sub newSigningKey {
  my ($secretKey, $dateStamp, $regionName, $serviceName) = @_;

  my $kSecret = "AWS4" . $secretKey;
  my $kDate = hmac_sha256($dateStamp, $kSecret);
  my $kRegion = hmac_sha256($regionName, $kDate);
  my $kService = hmac_sha256($serviceName, $kRegion);
  return hmac_sha256("aws4_request", $kService);
}

say "Step 1:  Create a canonical request:";
my $canonicalString = createCanonicalString($user, $ak, $date, $dateTimeStamp, $region, $expirySeconds, $host, $port);
say $canonicalString;
say "Step 2:  Create a string to sign:";
my $stringToSign = createStringToSign($dateTimeStamp, $canonicalString, $ak, $date, $region);
say $stringToSign;
say "Step 3:  Calculate the signature:";
my $signature = calculateSignature($stringToSign, newSigningKey($sk, $date, $region, $service));
say $signature;
say "Step 4:  Add the signing info to the request";
my $token = $requestWithoutSignature . "&X-Amz-Signature=" . $signature;
say $token;

# this has been used for generating known-working tokens while debugging. Take into account that
# the tokens have to be generated the same second to be the same
#my $other_token = `aws rds generate-db-auth-token --hostname $host --port $port --username $user --region $region`;
#chomp $other_token;
#say $other_token;


# Now that we have a token, connect to mysql 

# DBD::mysql doesn't have a mysql_clear_password option, but luckily we can use the LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN
#  env variable to to transmit the token in cleartext.
$ENV{ LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN } = 1;

# We need to use the mysql_ssl option for RDS to accept our token
my $dbh = DBI->connect("dbi:mysql:host=$host;mysql_ssl=1", $user, $token, { RaiseError => 1 });

my $info = $dbh->selectrow_hashref("SELECT VERSION() as version");

say "I've connected succesfully to MySQL at $host. It's version ", $info->{ version };
