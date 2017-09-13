require 'chef/provisioning/azurerm/azure_resource'

class Chef
  class Resource
    class AzureResourceTemplate < Chef::Provisioning::AzureRM::AzureResource
      resource_name :azure_resource_template
      actions :deploy, :validate, :nothing
      default_action :deploy
      attribute :name, kind_of: String, name_attribute: true
      attribute :resource_group, kind_of: String
      attribute :template_source, kind_of: String
      attribute :parameters, kind_of: Hash
      attribute :chef_extension, kind_of: Hash
      attribute :outputs, kind_of: Hash
      attribute :common_info, kind_of: Hash
      attribute :queue_name, kind_of: String
      attribute :storage_name, kind_of: String
      attribute :storage_key, kind_of: String
      attribute :parse_output, kind_of: String
    end
  end
end

