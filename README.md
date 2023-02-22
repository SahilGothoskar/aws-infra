### AWS Virtual Private Cloud (VPC) Configuration

```

This Terraform configuration creates a Virtual Private Cloud (VPC) in Amazon Web Services (AWS) with the following components:

- A VPC with a specific CIDR block of 10.0.0.0/16 and tagged with "main-vpc".
- 6 subnets, 3 public and 3 private, with CIDR blocks generated based on the count.index.
- An Internet Gateway with the tag "main-igw" and associated with the VPC.
- 2 route tables, public and private, with respective tags "public-route-table" and "private-route-table".
- Public route table associated with public subnets and private route table associated with private subnets.
- A default route to the internet through the main Internet Gateway.

```
### AWS Provider Configuration
```

The provider block sets up the AWS provider for Terraform and allows for the region to be set using the var.region variable. The access 
and secret keys are also specified. This setup makes it possible to use a different region by simply changing the value of var.region.

```
### Subnet Configuration

```
The subnets are created in the aws_subnet block with the public subnets tagged with "public-${count.index + 1}" and private subnets tagged with "private-${count.index + 1}". The CIDR blocks for these subnets are generated based on the value of count.index.

```

### Internet Gateway Configuration

```
An Internet Gateway is created in the aws_internet_gateway block and tagged with "main-igw". It is associated with the main VPC.

```

### Route Table Configuration

```

The public and private route tables are created in the aws_route_table block, with respective tags "public-route-table" and 
"private-route-table".

```
### Route Table Association Configuration

```

The public route table is associated with the public subnets in the aws_route_table_association block, and the private route table is associated with the private subnets.

```
### Default Route Configuration

```

A default route to the internet is created in the aws_route block, where the destination CIDR block is set to 0.0.0.0/0 and the gateway is the main Internet Gateway.

```

## To run the code


```
# terraform init 

# terraform plan  ( It will prompt to enter the ami-id and region)

# terraform apply --auto-approve (Enter the ami-id generated from the packer build  and run in the required region )

```