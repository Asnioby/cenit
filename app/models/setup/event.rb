module Setup
  class Event < Base
    include Setup::Enum

    belongs_to :model, class_name: Setup::ModelSchema.name

    field :name, type: String
    field :attr, type: String
    field :rule, type: String
    field :condition, type: String
    field :value, type: String

    validates_presence_of :name, :model
    
    rails_admin do
      field :name
      field :model
      field :rule
      field :condition
      field :value
      
      configure :model do
        associated_collection_scope do
          #Setup::ModelSchema.after_save_callback
          Webhook = bindings[:object]
          proc { Setup::ModelSchema.where(after_save_callback: true) }
        end
      end
      
      object_label_method do
        :full_name
      end
    end

    # The default events 'created' and 'updated' have attr nil.
    # for this reason when applay is call without attr its return true
    #
    # Examples:
    #  2) Generate and event if the product haven't price 
    #  !product_1.price.present? <==> attr: price, rule: 'no longer present'
    #
    #  1) Generate and event if the order have status 'complete'
    #  order_1.status == 'complete'?  <==> attr: status, rule: 'has changed to a value'; condition: '==' ; value: 'complete'
    #
    # TODO: eval object value before and now
    
    def apply( object )
      return true if attr.nil?
      
      result = case rule
      when 'now present'
        object.send(attr).present?
      when 'no longer present'
        !object.send(attr).present?
      when 'has changed to a value'
        eval [object.send(attr), condition, value].join(' ')
      end
      
      return result
    end

    def throw( object = nil )
      if self.apply(object) 
        flows = Setup::Flow.where( event: self )
        flows.each { |f| f.process(object) } if flows.any? 
      end
    end
    
    def full_name
      "#{self.name}  #{model.name.downcase if model && model.name.present? }" 
    end  

  end
end
