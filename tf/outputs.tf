# Output Values:

# Domain
output "domainname" {
  value = "${var.route53_subdomain}.${var.route53_domain}"
}

# Instances 
output "instance-private-ips" {
  value = ["${aws_instance.dc-instance.*.private_ip}"]
}
output "instance-public-ips" {
  value = ["${aws_eip.instance-eip.*.public_ip}"]
}
output "instance-names" {
  value = ["${aws_route53_record.dc-instance.*.name}"]
}
