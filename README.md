# Connecting to an RDS or Aurora database with IAM authentication

Amazon Web Services RDS (Relational Database Service) hosts MySQL databases in the AWS cloud for you. The hosted
MySQLs are mostly like any standard MySQL that you would install on an EC2 instance with a couple of tricks down
their sleeves. One of said tricks is letting you authenticate to the database with IAM credentials (the Access
Keys and Secret Keys that you use to authenticate to the APIs) instead of using MySQLs traditional users and 
passwords.

## Why use IAM credentials for databases

RDS databases start out with one initial user and password that you have configured. That user is an administrative
"root" user that has lots of power. You shouldn't be using those credentials in you applications!

- Using IAM, the database users are defined outside of your databases, so you can define from IAM to what RDS instances
- You can use IAM roles to connect to your RDS instances so that you don't need to manage long term Access and Secret Keys

## I want to do that too

If you like the idea of using IAM credentials to connect to your RDS instance, and you read the RDS manual about 
this feature, you might think "this isn't for me", since the manual only explains how to connect with the 
[https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.Connecting.AWSCLI.html](mysql command line client) and 
[https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.Connecting.html](Java).

## Tell me how it works

Basically you need to create an RDS with the "IAM database authentication" feature enabled, and an IAM user that lets you

```
{ "Version":"2012-10-17",
  "Statement":[{
    "Effect":   "Allow",
    "Action":   ["rds-db:connect"],
    "Resource": ["arn:aws:rds-db:eu-west-1:AWS_ACCOUNT_ID:dbuser:RDS_INSTANCE_IDENTIFIER/DATABASEUSER"]
  }]
}
```

`AWS_ACCOUNT_ID` is your 12 digit AWS account identifier, which you can find in the upper right part of the AWS console (or in any ARN for your resources. See below in the example how you can obtain it).

`RDS_INSTANCE_ID` is the RDS "Resource Id" (watch out! It's not the RDS instance name!) of an RDS instance, or `*` to grant permission to authenticate to any RDS instance.

`DATABASEUSER` is the name of a user created in the MySQL database with a `CREATE USER` statement, and later a `GRANT`, so it can access
some database.

You also have to appropiately set up a database user to be able to authenticate with the new scheme (note that you can still create and use non-IAM-autheticated MySQL users, since the IAM authenticated ones have to be explicitly enabled).

```
CREATE USER DATABASEUSER IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';
GRANT ALL ON mydb.* TO DATABASEUSER\@'%';
```

You may have thought that you were going connect to the RDS instance with the Access Key as the user and the Secret Key as the password to your database. One little known thing about how AWS authenticates API requests is that the Secret Key never leaves the client machine (it never gets transmitted to the servers. Instead the Secret Key, is used to sign a request, so that AWS can verify that it's been singed with the Secret Key. This means that requests can get intercepted, and that isn't enough for the interceptor to generate new requests. So the RDS IAM authentication uses the same signing scheme that the APIs use.

Since the authentication scheme has to transmit a signature, we have to use a little known capability of the MySQL client to transmit passwords in clear. The default protocol of MySQL sends the password that you specify to the mysql client hashed to the server. Since we have a signature that has to arrive intact to the MySQL server, it shouldn't get manipulated (if it gets hashed, then the server cannot make sense of it), and that's why we use mysql clients capability of sending whatever you specify as a password over the wire.

For added protection, you __have__ to encrypt the MySQL connection to use the IAM authentication scheme (or else the database will not authenticate the user).

## Show me how to do it!

These instructions are made so you can copy and paste them into your console session. You need the `aws` command line client installed and configured.

First we create an RDS instance with MySQL
```
RDS_NAME=RDSIAMTest
RDS_REGION=eu-west-1
DB_NAME=ExampleDB
DB_ROOT_USER=master
DB_ROOT_PASS=master123
aws rds create-db-instance \
    --region $RDS_REGION \
    --db-instance-identifier $RDS_NAME \
    --db-instance-class db.t2.micro \
    --engine MySQL \
    --port 3306 \
    --allocated-storage 5 \
    --db-name $DB_NAME \
    --master-username $DB_ROOT_USER \
    --master-user-password $DB_ROOT_PASS \
    --backup-retention-period 0 \
    --enable-iam-database-authentication \
    --publicly-accessible \
    --no-multi-az
```

Open the RDS instance so you can connect to it

```
RDS_SG=`aws rds describe-db-instances --region $RDS_REGION --db-instance-identifier $RDS_NAME --query DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId --output text`
MY_IP=`curl -s http://checkip.amazonaws.com/`
aws ec2 authorize-security-group-ingress --region $RDS_REGION --group-id $RDS_SG --protocol all --port 3306 --cidr $MY_IP/32
```

Create an IAM user with a policy that will let us connect to the database

```
IAM_USER=rdsiamtest
aws iam create-user --user-name $IAM_USER
AWS_ACCOUNT_ID=`aws iam get-user --user-name $IAM_USER --query User.Arn --output text | cut -d: -f5`
RDS_RESOURCE_ID=`aws rds describe-db-instances --region $RDS_REGION --db-instance-identifier $RDS_NAME --query DBInstances[0].DbiResourceId --output text`
DB_CONNECT_USER=dbiamuser

IAM_POLICY_ARN=`aws iam create-policy --policy-name ${IAM_USER} --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"rds-db:connect\"],\"Resource\":[\"arn:aws:rds-db:eu-west-1:$AWS_ACCOUNT_ID:dbuser:$RDS_RESOURCE_ID/$DB_CONNECT_USER\"]}]}" --query Policy.Arn --output text`
aws iam attach-user-policy --user-name $IAM_USER --policy-arn $IAM_POLICY_ARN
AWS_SECRET_KEY=`aws iam create-access-key --user-name $IAM_USER --output text --query AccessKey.SecretAccessKey`
AWS_ACCESS_KEY=`aws iam list-access-keys --user-name $IAM_USER --output text --query AccessKeyMetadata[0].AccessKeyId`
```

Now we're going to create a MySQL user that lets you connect to the database with `dbiamuser`. Wait for the RDS instance to be completely created before executing the following commands.

```
DB_HOST=`aws rds describe-db-instances --region $RDS_REGION --db-instance-identifier $RDS_NAME --query DBInstances[0].Endpoint.Address --output text`

echo "CREATE USER $DB_CONNECT_USER IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS'" | mysql -h $DB_HOST -u $DB_ROOT_USER -p$DB_ROOT_PASS
echo "GRANT ALL ON $DB_NAME.* TO $DB_CONNECT_USER@'%'" | mysql -h $DB_HOST -u $DB_ROOT_USER -p$DB_ROOT_PASS
```

And now "la piece de résistance"! We're going to connect to the RDS instance with Perl! There us a script in this repository that will connect you to the RDS instance, calculating the signature beforehand.

```
./rds_iam_connect.pl $DB_HOST $DB_CONNECT_USER $AWS_ACCESS_KEY $AWS_SECRET_KEY
```

Note: if you get an errors talking about "can't use DBI" or "can't find the mysql driver", you may need to install Perls DataBase Interface. `apt-get install -y libdbd-mysql-perl` will do all the magic for you if you're on Debian/Ubuntu.

## Some observations

- The first time you connect, there will be a small delay, but don't despair. Subsequent connections are immediate
- The fact that you have to connect to the database to enable a user to connect with IAM credentials can be a bit frustrating if you're creating new RDS instances, via CloudFormation, for example. A workaround can be creating the RDS instances from database snapshots that already have the users created.
- If the instance that connects to your RDS is running in EC2 or ECS don't generate an IAM user, and instead use an IAM Role so that you don't have to manage the Access and Secret keys!
- Administrative IAM users (all actions on all resources) will also be able to authenticate to your RDS instance with any IAM-enabled user. This may not be appearant when you enable the IAM authentication feature.
- The fact that and IAM user can authenticate on an instance doesn't mean he can do so from any place. Remember that Security Groups have to be properly open to the origin of the connection
- When creating the IAM policy, the IAM console warns about the policy "not granting any permissions", and the service "rds-db" not being recognized. Don't worry about it (just check that your policy is correct), as the policy validators don't seem to know about these policies yet.
- The first time I built a restrictive IAM policy for connecting to an RDS instance I put the RDS instance name in the place of the RDS_RESOURCE_ID field `arn:aws:rds-db:eu-west-1:$AWS_ACCOUNT_ID:dbuser:$RDS_RESOURCE_ID/$DB_CONNECT_USER`. They are not the same (and thus the policy won't work). To find the correct RDS_RESOURCE_ID, you have to look in the Details section of your RDS instance.

## More info

[https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.Connecting.Java.html](How to generate auth tokens)

[https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.IAMPolicy.html](Notes on how to build the IAM policy)

## Author, Copyright and License

This article was authored by Jose Luis Martinez Torres

This article is (c) 2018 CAPSiDE, Licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)

The canonical, up-to-date source is [GitHub](https://github.com/pplu/perl-rds-iam-authentication). Feel free to
contribute back
