module KindAndEtag

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def kind
      'arvados#' + self.to_s.camelcase(:lower)
    end
  end

  def kind
    self.class.kind
  end

  def etag
    Digest::MD5.hexdigest(self.inspect).to_i(16).to_s(36)
  end
end
