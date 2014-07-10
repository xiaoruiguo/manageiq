# TODO: Separate collection from parsing (perhaps collecting in parallel a la RHEVM)

module EmsRefresh::Parsers
  class Openstack < Cloud
    def self.ems_inv_to_hashes(ems, options = nil)
      self.new(ems, options).ems_inv_to_hashes
    end

    def initialize(ems, options = nil)
      @ems           = ems
      @connection    = ems.connect
      @options       = options || {}
      @data          = {}
      @data_index    = {}
      @known_flavors = Set.new

      @os_handle            = ems.openstack_handle
      @network_service      = @os_handle.detect_network_service
      @network_service_name = @os_handle.network_service_name
      @image_service        = @os_handle.detect_image_service
      @image_service_name   = @os_handle.image_service_name
    end

    def ems_inv_to_hashes
      log_header = "MIQ(#{self.class.name}.#{__method__}) Collecting data for EMS name: [#{@ems.name}] id: [#{@ems.id}]"

      $fog_log.info("#{log_header}...")
      get_flavors
      get_availability_zones
      get_tenants
      get_key_pairs
      get_security_groups
      get_networks
      # get_hosts
      get_images
      get_servers
      get_volumes
      get_snapshots
      get_object_store
      get_floating_ips
      $fog_log.info("#{log_header}...Complete")

      link_vm_genealogy
      link_storage_associations
      filter_unused_disabled_flavors
      clean_up_extra_flavor_keys

      @data
    end

    private

    def detect_volume_service
      [@ems.connect_volume, :cinder]
    rescue MiqException::ServiceNotAvailable
      [@connection, :nova]
    end

    def detect_storage_service
      [@ems.connect_storage, :swift]
    rescue MiqException::ServiceNotAvailable
      [nil, :none]
    end

    def servers
      @servers ||= @connection.servers_for_accessible_tenants
    end

    def security_groups
      @security_groups ||= @network_service.security_groups_for_accessible_tenants
    end

    def networks
      @networks ||= @network_service.networks
    end

    def volumes
      @volumes ||= @volume_service.volumes.all(:detailed => true, :all_tenants => true)
    end

    def get_flavors
      flavors = @connection.flavors
      process_collection(flavors, :flavors) { |flavor| parse_flavor(flavor) }
    end

    def get_private_flavor(id)
      private_flavor = @connection.flavors.get(id)
      process_collection([private_flavor], :flavors) { |flavor| parse_flavor(flavor) }
    end

    def get_availability_zones
      azs = servers.collect(&:availability_zone)
      azs.concat(volumes.collect(&:availability_zone)).compact!
      azs.uniq!
      azs << nil # force the null availability zone for openstack
      process_collection(azs, :availability_zones) { |az| parse_availability_zone(az) }
    end

    def get_tenants
      tenants = @connection.tenants
      process_collection(tenants, :cloud_tenants) { |tenant| parse_tenant(tenant) }
    end

    def get_key_pairs
      kps = @connection.key_pairs
      process_collection(kps, :key_pairs) { |kp| parse_key_pair(kp) }
    end

    def get_security_groups
      process_collection(security_groups, :security_groups) { |sg| parse_security_group(sg) }
      get_firewall_rules
    end

    def get_firewall_rules
      security_groups.each do |sg|
        new_sg = @data_index.fetch_path(:security_groups, sg.id)
        new_sg[:firewall_rules] = sg.security_group_rules.collect { |r| parse_firewall_rule(r) }
      end
    end

    def get_networks
      return unless @network_service_name == :neutron

      process_collection(networks, :cloud_networks) { |n| parse_network(n) }
      get_subnets
    end

    def get_subnets
      return unless @network_service_name == :neutron

      networks.each do |n|
        new_net = @data_index.fetch_path(:cloud_networks, n.id)
        new_net[:cloud_subnets] = n.subnets.collect { |s| parse_subnet(s) }
      end
    end

    # def get_hosts
    #   hosts = @connection.hosts.select { |h| h.service == "compute" }
    #   process_collection(hosts, :hosts) { |host| parse_host(host) }
    # end

    def get_volumes
      # TODO: support volumes through :nova as well?
      return unless @volume_service_name == :cinder
      process_collection(volumes, :cloud_volumes) { |volume| parse_volume(volume) }
    end

    def get_snapshots
      # TODO: support snapshots through :nova as well?
      return unless @volume_service_name == :cinder
      # TODO: Implement :all_tenants flag for snapshots in Fog.
      snapshots = []
      @identity_service.tenants.each do |t|
        next if t.name == "services"
        begin
          volume_service_for_tenant = @ems.connect(:service => 'Volume', :extra_opts => {:openstack_tenant => t.name})
        rescue Excon::Errors::Unauthorized => eeu_err
          next
        end
        snapshots += volume_service_for_tenant.list_snapshots.body['snapshots']
      end
      process_collection(snapshots, :cloud_volume_snapshots) { |snap| parse_snapshot(snap) }
    end

    def get_object_store
      return unless @storage_service_name == :swift
      # TODO: Implement :all_tenants flag for object store (Storage) in Fog,
      # if Swift supports it.
      @identity_service.tenants.each do |t|
        next if t.name == "services"
        begin
          storage_service_for_tenant = @ems.connect(:service => 'Storage', :extra_opts => {:openstack_tenant => t.name})
        rescue Excon::Errors::Unauthorized => eeu_err
          next
        end

        storage_service_for_tenant.directories.each do |fd|
          result = process_collection_item(fd, :cloud_object_store_containers) { |c| parse_container(c, t) }
          process_collection(fd.files, :cloud_object_store_objects) { |o| parse_object(o, result, t) }
        end
      end
    end

    def get_images
      images = @image_service.images_for_accessible_tenants
      process_collection(images, :vms) { |image| parse_image(image) }
    end

    def get_servers
      process_collection(servers, :vms) { |server| parse_server(server) }
    end

    def process_collection(collection, key, &block)
      collection.each { |item| process_collection_item(item, key, &block) }
    end

    def process_collection_item(item, key)
      @data[key] ||= []

      uid, new_result = yield(item)

      @data[key] << new_result
      @data_index.store_path(key, uid, new_result)
      new_result
    end

    def get_floating_ips
      ips = send("floating_ips_#{@network_service_name}")
      process_collection(ips, :floating_ips) { |ip| parse_floating_ip(ip) }
    end

    def floating_ips_neutron
      @network_service.floating_ips
    end

    # maintained for legacy nova network support
    def floating_ips_nova
      @network_service.addresses_for_accessible_tenants
    end

    def link_vm_genealogy
      @data[:vms].each do |vm|
        parent_vm_uid = vm.delete(:parent_vm_uid)
        parent_vm = @data_index.fetch_path(:vms, parent_vm_uid)
        vm[:parent_vm] = parent_vm unless parent_vm.nil?
      end
    end

    def link_storage_associations
      @data[:cloud_volumes].each do |cv|
        #
        # Associations between volumes and the snapshots on which
        # they are based, if any.
        #
        base_snapshot_uid = cv.delete(:snapshot_uid)
        base_snapshot = @data_index.fetch_path(:cloud_volume_snapshots, base_snapshot_uid)
        cv[:base_snapshot] = base_snapshot unless base_snapshot.nil?
      end
    end

    def parse_flavor(flavor)
      uid = flavor.id

      new_result = {
        :type    => "FlavorOpenstack",
        :ems_ref => uid,
        :name    => flavor.name,
        :enabled => !flavor.disabled,
        :cpus    => flavor.vcpus,
        :memory  => flavor.ram.megabytes,

        # Extra keys
        :root_disk      => flavor.disk.to_i.gigabytes,
        :ephemeral_disk => flavor.ephemeral.to_i.gigabytes,
        :swap_disk      => flavor.swap.to_i.megabytes
      }

      return uid, new_result
    end

    def parse_availability_zone(az)
      if az.nil?
        uid        = "null_az"
        new_result = {
          :type    => "AvailabilityZoneOpenstackNull",
          :ems_ref => uid
        }
      else
        uid = name = az
        new_result = {
          :type    => "AvailabilityZoneOpenstack",
          :ems_ref => uid,
          :name    => name
        }
      end

      return uid, new_result
    end

    def parse_tenant(tenant)
      uid = tenant.id

      new_result = {
        :name        => tenant.name,
        :description => tenant.description,
        :enabled     => tenant.enabled,
        :ems_ref     => uid,
      }

      return uid, new_result
    end

    def self.key_pair_type
      'AuthKeyPairOpenstack'
    end

    def self.security_group_type
      'SecurityGroupOpenstack'
    end

    def parse_security_group(sg)
      uid, security_group = super
      security_group[:cloud_tenant] = @data_index.fetch_path(:cloud_tenants, sg.tenant_id)
      return uid, security_group
    end

    # TODO: Should ICMP protocol values have their own 2 columns, or
    #   should they override port and end_port like the Amazon API.
    def parse_firewall_rule(rule)
      send("parse_firewall_rule_#{@network_service_name}", rule)
    end

    def parse_firewall_rule_neutron(rule)
      direction = (rule.direction == "egress") ? "outbound" : "inbound"

      {
        :direction             => direction,
        :ems_ref               => rule.id.to_s,
        :host_protocol         => rule.protocol.to_s.upcase,
        :network_protocol      => rule.ethertype.to_s.upcase,
        :port                  => rule.port_range_min,
        :end_port              => rule.port_range_max,
        :source_security_group => rule.remote_group_id,
        :source_ip_range       => rule.remote_ip_prefix,
      }
    end

    def parse_firewall_rule_nova(rule)
      {
        :direction             => "inbound",
        :ems_ref               => rule.id.to_s,
        :host_protocol         => rule.ip_protocol.to_s.upcase,
        :port                  => rule.from_port,
        :end_port              => rule.to_port,
        :source_security_group => data_security_groups_by_name[rule.group["name"]],
        :source_ip_range       => rule.ip_range["cidr"],
      }
    end

    def parse_network(network)
      uid     = network.id
      status  = (network.status.to_s.downcase == "active") ? "active" : "inactive"

      new_result = {
        :name            => network.name,
        :ems_ref         => uid,
        :status          => status,
        :enabled         => network.admin_state_up,
        :external_facing => network.router_external,
        :cloud_tenant    => @data_index.fetch_path(:cloud_tenants, network.tenant_id)
      }
      return uid, new_result
    end

    def parse_subnet(subnet)
      {
        :name             => subnet.name,
        :ems_ref          => subnet.id,
        :cidr             => subnet.cidr,
        :network_protocol => "ipv#{subnet.ip_version}",
        :gateway          => subnet.gateway_ip,
        :dhcp_enabled     => subnet.enable_dhcp,
      }
    end

    def parse_volume(volume)
      if (attachment = volume.attachments.first)
        server_id = attachment["server_id"]
        vm = @data_index.fetch_path(:vms, server_id)
      end
      uid = volume.id
      new_result = {
        :ems_ref           => uid,
        :name              => volume.display_name,
        :status            => volume.status,
        :bootable          => volume.attributes['bootable'],
        :creation_time     => volume.created_at,
        :description       => volume.display_description,
        :volume_type       => volume.volume_type,
        :snapshot_uid      => volume.snapshot_id,
        :size              => volume.size.to_i.gigabytes,
        :tenant            => @data_index.fetch_path(:cloud_tenants, volume.attributes['os-vol-tenant-attr:tenant_id']),
        :availability_zone => @data_index.fetch_path(:availability_zones, volume.availability_zone || "null_az"),
      }

      volume.attachments.each do |a|
        dev = File.basename(a['device'])
        vm = @data_index.fetch_path(:vms, a['server_id'])
        disks = vm[:hardware][:disks]

        if (disk = disks.detect { |d| d[:location] == dev })
          disk[:size] = new_result[:size]
        else
          disk = add_instance_disk(disks, new_result[:size], dev, "OpenStack Volume")
        end

        if disk
          disk[:backing]      = new_result
          disk[:backing_type] = 'CloudVolume'
        end
      end

      return uid, new_result
    end

    def parse_snapshot(snap)
      uid = snap['id']
      new_result = {
        :ems_ref       => uid,
        :name          => snap['display_name'],
        :status        => snap['status'],
        :creation_time => snap['created_at'],
        :description   => snap['display_description'],
        :size          => snap['size'].to_i.gigabytes,
        :tenant        => @data_index.fetch_path(:cloud_tenants, snap['os-extended-snapshot-attributes:project_id']),
        :volume        => @data_index.fetch_path(:cloud_volumes, snap['volume_id'])
      }
      return uid, new_result
    end

    def parse_container(container, tenant)
      uid = "#{tenant.id}/#{container.key}"
      new_result = {
        :ems_ref      => uid,
        :key          => container.key,
        :object_count => container.count,
        :bytes        => container.bytes,
        :tenant       => @data_index.fetch_path(:cloud_tenants, tenant.id)
      }
      return uid, new_result
    end

    def parse_object(obj, container, tenant)
      uid = obj.etag
      new_result = {
        :ems_ref        => uid,
        :etag           => obj.etag,
        :last_modified  => obj.last_modified,
        :content_length => obj.content_length,
        :key            => obj.key,
        :content_type   => obj.content_type,
        :container      => container,
        :tenant         => @data_index.fetch_path(:cloud_tenants, tenant.id)
      }
      return uid, new_result
    end

    def parse_image(image)
      uid = image.id

      parent_server_uid = parse_image_parent_id(image)

      new_result = {
        :type        => "TemplateOpenstack",
        :uid_ems     => uid,
        :ems_ref     => uid,
        :name        => image.name,
        :vendor      => "openstack",
        :power_state => "never",
        :template    => true,
      }
      new_result[:parent_vm_uid] = parent_server_uid unless parent_server_uid.nil?
      new_result[:cloud_tenant]  = @data_index.fetch_path(:cloud_tenants, image.owner) if image.owner

      return uid, new_result
    end

    def parse_image_parent_id(image)
      image_parent = @image_service_name == :glance ? image.copy_from : image.server
      image_parent["id"] if image_parent
    end

    def parse_server(server)
      uid = server.id

      power_state =
        case server.os_ext_sts_power_state.to_i
        when 1;          "on"         # 1 = RUNNING
        when 2, 3, 7, 9; "suspended"  # 2 = BLOCKED, 3 = PAUSED, 7 = SUSPENDED, 9 = BUILDING
        when 4, 5, 6, 8; "off"        # 4 = SHUTDOWN, 5 = SHUTOFF, 6 = CRASHED, 8 = FAILED
        else             "unknown"    # 0 = NO STATE, et. al.
        end

      flavor_uid = server.flavor["id"]
      @known_flavors << flavor_uid
      flavor = @data_index.fetch_path(:flavors, flavor_uid)
      if flavor.nil?
        get_private_flavor(flavor_uid)
        flavor = @data_index.fetch_path(:flavors, flavor_uid)
      end

      private_network = {:ipaddress => server.private_ip_address}.delete_nils
      public_network  = {:ipaddress => server.public_ip_address}.delete_nils

      # parent_host      = @data_index.fetch_path(:hosts, server.os_ext_srv_attr_host)
      parent_image_uid = server.image["id"]

      new_result = {
        :type             => "VmOpenstack",
        :uid_ems          => uid,
        :ems_ref          => uid,
        :name             => server.name,
        :vendor           => "openstack",
        :power_state      => power_state,
        :connection_state => "connected",

        :hardware => {
          :numvcpus         => flavor[:cpus],
          :cores_per_socket => 1,
          :logical_cpus     => flavor[:cpus],
          :memory_cpu       => flavor[:memory] / (1024 * 1024), # memory_cpu is in megabytes
          :disk_capacity    => flavor[:root_disk] + flavor[:ephemeral_disk] + flavor[:swap_disk],
          :disks            => [], # Filled in later conditionally on flavor
          :networks         => [], # Filled in later conditionally on what's available
        },

        # :host => parent_host,
        :flavor            => flavor,
        :availability_zone => @data_index.fetch_path(:availability_zones, server.availability_zone || "null_az"),
        :key_pairs         => [@data_index.fetch_path(:key_pairs, server.key_name)].compact,
        :security_groups   => server.security_groups.collect { |sg| @data_index.fetch_path(:security_groups, sg.id) }.compact,
        :cloud_tenant      => @data_index.fetch_path(:cloud_tenants, server.tenant_id),
      }
      new_result[:hardware][:networks] << private_network.merge(:description => "private") unless private_network.blank?
      new_result[:hardware][:networks] << public_network.merge(:description => "public")   unless public_network.blank?

      new_result[:parent_vm_uid] = parent_image_uid unless parent_image_uid.nil?

      disks = new_result[:hardware][:disks]
      dev = "vda"

      # TODO: flavor[:root_disk] == 0 should take root disk size from image size.
      if (sz = flavor[:root_disk]) == 0
        sz = 1.gigabytes
      end
      add_instance_disk(disks, sz, dev.dup,       "Root disk")
      sz = flavor[:ephemeral_disk]
      add_instance_disk(disks, sz, dev.succ!.dup, "Ephemeral disk") unless sz.zero?
      sz = flavor[:swap_disk]
      add_instance_disk(disks, sz, dev.succ!.dup, "Swap disk")      unless sz.zero?

      return uid, new_result
    end

    def parse_floating_ip(ip)
      send("parse_floating_ip_#{@network_service_name}", ip)
    end

    def parse_floating_ip_neutron(ip)
      uid     = ip.id
      address = ip.floating_ip_address

      associated_vm = find_vm_associated_with_floating_ip(address)

      new_result = {
        :type         => "FloatingIpOpenstack",
        :ems_ref      => uid,
        :address      => address,

        :vm           => associated_vm,
        :cloud_tenant => @data_index.fetch_path(:cloud_tenants, ip.tenant_id)
      }

      return uid, new_result
    end

    # maintained for legacy nova network support
    def parse_floating_ip_nova(ip)
      uid     = ip.id
      address = ip.ip

      associated_vm = find_vm_associated_with_floating_ip(address)

      new_result = {
        :type    => "FloatingIpOpenstack",
        :ems_ref => uid,
        :address => address,

        :vm      => associated_vm
      }

      return uid, new_result
    end

    #
    # Helper methods
    #

    def find_vm_associated_with_floating_ip(ip_address)
      @data[:vms].detect do |v|
        v.fetch_path(:hardware, :networks).to_miq_a.detect do |n|
          n[:description] == "public" && n[:ipaddress] == ip_address
        end
      end
    end

    def clean_up_extra_flavor_keys
      @data[:flavors].each do |f|
        f.delete(:root_disk)
        f.delete(:ephemeral_disk)
        f.delete(:swap_disk)
      end
    end

    def data_security_groups_by_name
      @data_security_groups_by_name ||= @data[:security_groups].index_by { |sg| sg[:name] }
    end

    def add_instance_disk(disks, size, location, name)
      super(disks, size, location, name, "openstack")
    end
  end
end
