# Instances:

# Single node cluster for test deployments
#
resource "aws_instance" "dc-instance" {

  instance_type = "${var.aws_instance_type}"
  ami           = "${var.aws_ami}"
  key_name      = "${var.aws_key_name}"

  root_block_device {
    volume_size = "${var.volume_size_root}"
    volume_type = "gp2"
    delete_on_termination = true
  }

  # second disk
  ebs_block_device {
    device_name = "/dev/sdb"
    volume_size = "${var.volume_size_second_disk}"
    volume_type = "gp2"
    delete_on_termination = true
  }

  iam_instance_profile = "${aws_iam_instance_profile.instance_instance_profile.id}"

  vpc_security_group_ids = ["${aws_security_group.dc-instance-sg.id}"]
  subnet_id = "${aws_subnet.dc-subnet1.id}"

  user_data = "${file("userdata.sh")}"

  count = "${var.instance_node_count}"

  tags = {
    Name = "${var.prefix}-instance${count.index + 1}"
  }
}

