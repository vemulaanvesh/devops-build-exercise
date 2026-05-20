###############################################################################
# Remote state.
#
# Bootstrap (one-time, before first apply): create the state bucket + DDB
# table out-of-band (CloudFormation, a separate boot Terraform stack, or
# `aws s3api create-bucket` + `aws dynamodb create-table`). After that this
# block manages remote state for all future applies.
#
# Bucket: <account>-tfstate-prod
# Key:    underwriting-agent/prod/terraform.tfstate
# Lock:   tfstate-locks  (DynamoDB, hash key 'LockID' string)
###############################################################################

terraform {
  backend "s3" {
    bucket         = "REPLACE-ME-tfstate-prod"
    key            = "underwriting-agent/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/tfstate"
    dynamodb_table = "tfstate-locks"
    use_lockfile   = true # Terraform 1.10+ S3-native locking; DDB kept for backward compat
  }
}
