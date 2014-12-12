module RailsAdmin
  module Config
    module Actions
      class LoadModel < RailsAdmin::Config::Actions::Base

        register_instance_option :only do
          Setup::DataType
        end

        register_instance_option :member do
          true
        end

        register_instance_option :http_methods do
          [:get]
        end

        register_instance_option :visible do
          authorized? && !bindings[:object].loaded?
        end

        register_instance_option :controller do
          proc do
            if model = @object.model
              flash[:notice] = "Model #{@object.name} is already loaded!"
            else
              begin
                @object.auto_load_model = @object.activated = true
                @object.save
                model = @object.load_model
                RailsAdmin::AbstractModel.model_loaded(model)
                flash[:success] = "Model #{@object.name} loaded!"
              rescue Exception => ex
                flash[:error] = "Error loading model #{@object.name}: #{ex.message}"
              end
            end
            redirect_to rails_admin.show_path(model_name: Setup::DataType.to_s.underscore, id: @object.id)
          end
        end

        register_instance_option :link_icon do
          'icon-play-circle'
        end

        register_instance_option :pjax? do
          false
        end
      end
    end
  end
end