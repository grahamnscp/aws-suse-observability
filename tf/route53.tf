# Route53 for instances

# dc-instance entries
resource "aws_route53_record" "dc-instance" {
  zone_id = "${var.route53_zone_id}"
  count = "${var.instance_node_count}"
  name = "${var.prefix}-instance${count.index + 1}.${var.route53_subdomain}.${var.route53_domain}"
  type = "A"
  ttl = "300"
  #records = ["${element(aws_instance.dc-instance.*.public_ip, count.index)}"]
  records = ["${element(aws_eip.instance-eip.*.public_ip, count.index)}"]
}

resource "aws_route53_record" "rke" {
  zone_id = "${var.route53_zone_id}"
  name = "rke.${var.route53_subdomain}.${var.route53_domain}"
  type = "CNAME"
  ttl = "60"
  records = [aws_route53_record.dc-instance.0.name]
}

# observability elbs
resource "aws_route53_record" "obs" {
  zone_id = "${var.route53_zone_id}"
  name = "obs.${var.route53_subdomain}.${var.route53_domain}"
  type = "A"
  alias {
    name = "${aws_elb.obs-elb.dns_name}"
    zone_id = "${aws_elb.obs-elb.zone_id}"
    evaluate_target_health = false
  }
}
resource "aws_route53_record" "obs-otlp" {
  zone_id = "${var.route53_zone_id}"
  name = "otlp-grpc-obs.${var.route53_subdomain}.${var.route53_domain}"
  type = "A"
  alias {
    name = "${aws_elb.obs-elb.dns_name}"
    zone_id = "${aws_elb.obs-elb.zone_id}"
    evaluate_target_health = false
  }
}
resource "aws_route53_record" "obs-otlp-http" {
  zone_id = "${var.route53_zone_id}"
  name = "otlp-http-obs.${var.route53_subdomain}.${var.route53_domain}"
  type = "A"
  alias {
    name = "${aws_elb.obs-elb.dns_name}"
    zone_id = "${aws_elb.obs-elb.zone_id}"
    evaluate_target_health = false
  }
}

# dummp sample app
resource "aws_route53_record" "obs-app" {
  zone_id = "${var.route53_zone_id}"
  name = "wordpress-obs.${var.route53_subdomain}.${var.route53_domain}"
  type = "A"
  alias {
    name = "${aws_elb.obs-elb.dns_name}"
    zone_id = "${aws_elb.obs-elb.zone_id}"
    evaluate_target_health = false
  }
}

