require 'chef/provisioning/azurerm/azure_provider'
require 'azure'
require "json"

class Chef
  class Provider
    class AzureResourceTemplate < Chef::Provisioning::AzureRM::AzureProvider
      provides :azure_resource_template

      def whyrun_supported?
        true
      end

      action :deploy do
        converge_by("deploy or re-deploy Resource Manager template '#{new_resource.name}'") do
          begin
            result = resource_management_client.deployments.begin_create_or_update_async(new_resource.resource_group, new_resource.name, deployment).value!
            Chef::Log.debug("result: #{result.response.body}")
            follow_deployment_until_end_state
          rescue ::MsRestAzure::AzureOperationError => operation_error
            Chef::Log.error operation_error.response.body
            raise operation_error.response.inspect
          end
        end
      end

      def deployment
        deployment = Azure::ARM::Resources::Models::Deployment.new
        deployment.properties = Azure::ARM::Resources::Models::DeploymentProperties.new
        deployment.properties.template = template
        deployment.properties.mode = Azure::ARM::Resources::Models::DeploymentMode::Incremental
        deployment.properties.parameters = parameters_in_values_format
        deployment
      end

      def template
        template_src_file = new_resource.template_source
        Chef::Log.error "Cannot find file: #{template_src_file}" unless ::File.file?(template_src_file)
        template = JSON.parse(::IO.read(template_src_file))
        if new_resource.chef_extension
          machines = template['resources'].select { |h| h['type'] == 'Microsoft.Compute/virtualMachines' }
          machines.each do |machine|
            action_handler.report_progress "adding a Chef VM Extension with name: #{machine['name']} and location: #{machine['location']} "
            extension = chef_vm_extension(machine['name'], machine['location'])
            template['resources'] << JSON.parse(extension)
          end
        end
        template
      end

      def parameters_in_values_format
        parameters = new_resource.parameters.map do |key, value|
          { key.to_sym => { 'value' => value } }
        end
        parameters.reduce(:merge!)
      end

      def chef_vm_extension(machine_name, location)
        chef_server_url = Chef::Config[:chef_server_url]
        validation_client_name = Chef::Config[:validation_client_name]
        validation_key_content = ::File.read(Chef::Config[:validation_key])
        chef_environment = new_resource.chef_extension[:environment].empty? ? '_default' : new_resource.chef_extension[:environment]
        machine_name = "\'#{machine_name}\'" unless machine_name[0] == '['
        <<-EOH
          {
            "type": "Microsoft.Compute/virtualMachines/extensions",
            "name": "[concat(#{machine_name.delete('[]')},'/', 'chefExtension')]",
            "apiVersion": "2015-05-01-preview",
            "location": "#{location}",
            "dependsOn": [
              "[concat('Microsoft.Compute/virtualMachines/', #{machine_name.delete('[]')})]"
            ],
            "properties": {
              "publisher": "Chef.Bootstrap.WindowsAzure",
              "type": "#{new_resource.chef_extension[:client_type]}",
              "typeHandlerVersion": "#{new_resource.chef_extension[:version]}",
              "settings": {
                "bootstrap_options": {
                  "chef_node_name" : "[concat(#{machine_name.delete('[]')},'.','#{new_resource.resource_group}')]",
                  "chef_server_url" : "#{chef_server_url}",
                  "validation_client_name" : "#{validation_client_name}",
                  "environment" : "#{chef_environment}"
                },
                "runlist": "#{new_resource.chef_extension[:runlist]}"
              },
              "protectedSettings": {
                  "validation_key": "#{validation_key_content.gsub("\n", '\\n')}"
              }
            }
          }
        EOH
      end

      def follow_deployment_until_end_state
        end_provisioning_states = 'Canceled,Failed,Deleted,Succeeded'
        end_provisioning_state_reached = false
        until end_provisioning_state_reached
          list_outstanding_deployment_operations
          sleep 5
          deployment_provisioning_state = deployment_state
          end_provisioning_state_reached = end_provisioning_states.split(',').include?(deployment_provisioning_state)
        end
        action_handler.report_progress "Resource Template deployment reached end state of '#{deployment_provisioning_state}'."
        deployment_outputs = deployment_output
        if (new_resource.parse_output == 'True')
          write_outputs(new_resource.queue_name, new_resource.storage_name, new_resource.storage_key, new_resource.common_info, deployment_outputs, deployment_provisioning_state)
        end
      end

      def list_outstanding_deployment_operations
        end_operation_states = 'Failed,Succeeded'
        deployment_operations = resource_management_client.deployment_operations.list(new_resource.resource_group, new_resource.name)
        deployment_operations.each do |val|
          resource_provisioning_state = val.properties.provisioning_state
          unless val.properties.target_resource.nil?
            resource_name = val.properties.target_resource.resource_name
            resource_type = val.properties.target_resource.resource_type
          end
          end_operation_state_reached = end_operation_states.split(',').include?(resource_provisioning_state)
          unless end_operation_state_reached
            action_handler.report_progress "Resource #{resource_type} '#{resource_name}' provisioning status is #{resource_provisioning_state}\n"
          end
        end
      end

      def deployment_state
        deployments = resource_management_client.deployments.get(new_resource.resource_group, new_resource.name)
        Chef::Log.debug("deployments result: #{deployments.inspect}")
        deployments.properties.provisioning_state
      end

      def deployment_output
        deployments = resource_management_client.deployments.get(new_resource.resource_group, new_resource.name)
        deployment_outputs = deployments.properties.outputs
        if (!deployment_outputs.nil?)
          deployment_outputs
        else
          deployment_outputs = Hash.new
          deployment_outputs = {"deployment_output"=>"Didn't get any output from the deployment"}
        end
      end

      def write_outputs(queue_name, storage_name, storage_key, common_info, deployment_output, deployment_provisioning_state)
        Azure.config.storage_account_name = storage_name
        Azure.config.storage_access_key = storage_key
        queue_name = queue_name

        pp deployment_output
        provisioning_state = deployment_provisioning_state
        response_hash = Hash.new
        response_hash = {"deployment_output" => {"public_ip_address"=> deployment_output['publicIPAddress']['value'], "storage_account_name" => deployment_output['storageAccountName']['value'], "storage_key" => deployment_output['storageKey']['value']}}

        response_hash_result = common_info.merge(response_hash)
        response_hash_result_json = JSON.pretty_generate(response_hash_result)

        begin
          azure_queue_service = Azure::Queue::QueueService.new
          azure_queue_service.create_message(queue_name, response_hash_result_json)
        rescue
          puts $!
        end
      end
    end
  end
end
