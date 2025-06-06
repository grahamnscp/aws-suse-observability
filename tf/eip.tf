# elastic ips

# Associate Elastic IPs to Instances
resource "aws_eip" "instance-eip" {

  count = "${var.instance_node_count}"
  instance = "${element(aws_instance.dc-instance.*.id, count.index)}"

  tags = {
    Name = "${var.prefix}_instance${count.index + 1}"
  }

  depends_on = [aws_instance.dc-instance]
}
