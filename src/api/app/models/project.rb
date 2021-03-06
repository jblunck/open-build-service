require_dependency 'opensuse/backend'
require_dependency 'has_relationships'

class Project < ActiveRecord::Base
  include FlagHelper
  include CanRenderModel
  include HasRelationships
  has_many :relationships, dependent: :destroy, inverse_of: :project
  include HasRatings
  include HasAttributes

  class CycleError < APIException
    setup 'project_cycle'
  end
  class DeleteError < APIException
    setup 'delete_error'
  end
  # unknown objects and no read access permission are handled in the same way by default
  class ReadAccessError < APIException
    setup 'unknown_project', 404, 'Unknown project'
  end
  class UnknownObjectError < APIException
    setup 'unknown_project', 404, 'Unknown project'
  end
  class SaveError < APIException
    setup 'project_save_error'
  end
  class WritePermissionError < APIException
    setup 'project_write_permission_error'
  end
  class ForbiddenError < APIException
    setup('change_project_protection_level', 403,
          "admin rights are required to raise the protection level of a project (it won't be safe anyway)")
  end

  before_destroy :cleanup_before_destroy
  after_save 'Relationship.discard_cache'
  after_rollback :reset_cache
  after_rollback 'Relationship.discard_cache'
  after_initialize :init

  has_many :packages, :dependent => :destroy, inverse_of: :project
  has_many :attribs, :dependent => :destroy
  has_many :repositories, :dependent => :destroy, foreign_key: :db_project_id
  has_many :messages, :as => :db_object, :dependent => :delete_all
  has_many :watched_projects, :dependent => :destroy, inverse_of: :project

  has_many :linkedprojects, -> { order(:position) }, :class_name => 'LinkedProject', foreign_key: :db_project_id, :dependent => :delete_all

  has_many :taggings, :as => :taggable, :dependent => :delete_all
  has_many :tags, :through => :taggings

  has_many :download_stats
  has_many :downloads, :dependent => :delete_all, foreign_key: :db_project_id

  has_many :flags, dependent: :delete_all, inverse_of: :project

  # optional
  has_one :maintenance_incident, dependent: :delete, foreign_key: :db_project_id

  # projects can maintain other projects
  has_many :maintained_projects, :class_name => 'MaintainedProject', foreign_key: :maintenance_project_id, :dependent => :delete_all
  has_many :maintenance_projects, :class_name => 'MaintainedProject', foreign_key: :project_id, :dependent => :delete_all

  # develproject is history, use develpackage instead. FIXME3.0: clean this up
  has_many  :develprojects, :class_name => 'Project', :foreign_key => 'develproject_id'
  belongs_to :develproject, :class_name => 'Project'

  has_many :comments, :dependent => :destroy, inverse_of: :project, class_name: 'CommentProject'

  has_many :project_log_entries, :dependent => :delete_all

  default_scope { where('projects.id not in (?)', Relationship.forbidden_project_ids ) }

  validates :name, presence: true, length: { maximum: 200 }
  validates :title, length: { maximum: 250 }
  validates :type_id, presence: true
  validate :valid_name
 
  def self.deleted_instance
    prj = Project.find_by_name('deleted')
    return unless prj.nil?
    Project.create(name: 'deleted',
                   title: 'Place holder for a deleted project instance')
  end

  def cleanup_before_destroy
    CacheLine.cleanup_project(self.name)

    # find linking projects
    cleanup_linking_projects

    # find linking repositories
    cleanup_linking_repos

    # find linking target repositories
    cleanup_linking_targets

    # deleting local devel packages
    self.packages.each do |pkg|
      if pkg.develpackage_id
        pkg.develpackage_id = nil
        pkg.save
      end
    end
  end

  def revoke_requests
    # Find open requests with 'pro' as source or target and decline/revoke them.
    # Revoke if source or decline if target went away, pick the first action that matches to decide...
    # Note: As requests are a backend matter, it's pointless to include them into the transaction below
    self.open_requests_with_project_as_source_or_target.each do |request|
      request.bs_request_actions.each do |action|
        if action.source_project == self.name
          request.change_state({:newstate => 'revoked', :comment => "The source project '#{self.name}' was removed"})
          break
        end
        if action.target_project == self.name
          request.change_state({:newstate => 'declined', :comment => "The target project '#{self.name}' was removed"})
          break
        end
      end
    end

    # Find open requests which have a review involving this project (or it's packages) and remove those reviews
    # but leave the requests otherwise untouched.
    self.open_requests_with_by_project_review.each do |request|
      request.remove_reviews(:by_project => self.name)
    end
  end

  def find_repos(sym)
    self.repositories.each do |repo|
      repo.send(sym).each do |lrep|
        yield lrep
      end
    end
  end

  def update_instance(namespace='OBS', name='UpdateProject')
    # check if a newer instance exists in a defined update project
    if a = self.find_attribute(namespace, name) and a.values[0]
      return Project.find_by_name(a.values[0].value)
    end
    self
  end

  def cleanup_linking_projects
    #replace links to this project with links to the "deleted" project
    LinkedProject.transaction do
      LinkedProject.where(linked_db_project: self).each do |lp|
        id = lp.db_project_id
        lp.destroy
        Rails.cache.delete('xml_project_%d' % id)
      end
    end
  end

  def cleanup_linking_repos
    #replace links to this project repositories with links to the "deleted" repository
    find_repos(:linking_repositories) do |link_rep|
      link_rep.path_elements.includes(:link).each do |pe|
        next unless Repository.find(pe.repository_id).db_project_id == self.id
        if link_rep.path_elements.find_by_repository_id Repository.deleted_instance
          # repository has already a path to deleted repo
          pe.destroy
        else
          pe.link = Repository.deleted_instance
          pe.save
        end
        #update backend
        link_rep.project.write_to_backend
      end
    end
  end

  def cleanup_linking_targets
    #replace links to this projects with links to the "deleted" project
    find_repos(:linking_target_repositories) do |link_rep|
      link_rep.release_targets.includes(:target_repository).each do |rt|
        next unless Repository.find(rt.repository_id).db_project_id == self.id
        rt.target_repository = Repository.deleted_instance
        rt.save
        #update backend
        link_rep.project.write_to_backend
      end
    end
  end

  class << self

    def is_remote_project?(name, skip_access=false)
      lpro = find_remote_project(name, skip_access)
      
      lpro && lpro[0].is_remote?
    end

    def check_access?(dbp=self)
      return false if dbp.nil?
      # check for 'access' flag

      return true unless Relationship.forbidden_project_ids.include? dbp.id

      # simple check for involvement --> involved users can access
      # dbp.id, User.current
      grouprels = dbp.relationships.groups.to_a

      if grouprels
        ret = 0
        grouprels.each do |grouprel|
          # check if User.current belongs to group
          if grouprel and grouprel.group_id
            # LOCAL
            # if user is in group -> return true
            ret = ret + 1 if User.current.is_in_group?(grouprel.group_id)
            # LDAP
            # FIXME: please do not do special things here for ldap. please cover this in a generic group model.
            if CONFIG['ldap_mode'] == :on && CONFIG['ldap_group_support'] == :on
              if UserLdapStrategy.user_in_group_ldap?(User.current, group.group_id)
                ret = ret + 1
              end
            end
            #
          end
        end
        # relationship to package -> access
        return true if ret > 0
      end

      return false
    end

    # returns an object of project(local or remote) or raises an exception
    # should be always used when a project is required
    # The return value is either a Project for local project or an xml 
    # array for a remote project
    def get_by_name(name, opts = {})
      arel = where(name: name)
      if opts[:select]
         arel = arel.select(opts[:select])
         opts.delete :select
      end
      dbp = arel.first
      if dbp.nil?
        dbp, remote_name = find_remote_project(name)
        return dbp.name + ':' + remote_name if dbp
        raise UnknownObjectError, name
      end
      if opts[:includeallpackages]
         Package.joins(:flags).where(project_id: dbp.id).where("flags.flag='sourceaccess'").each do |pkg|
           raise ReadAccessError, name unless Package.check_access? pkg
         end
         opts.delete :includeallpackages
      end
      raise "unsupport options #{opts.inspect}" if opts.size > 0
      unless check_access?(dbp)
        raise ReadAccessError, name
      end
      return dbp
    end

    def get_maintenance_project(at=nil)
      # hardcoded default. frontends can lookup themselfs a different target via attribute search
      at ||= AttribType.find_by_namespace_and_name!('OBS','MaintenanceProject')
      maintenanceProject = Project.find_by_attribute_type(at).first
      unless maintenanceProject and check_access?(maintenanceProject)
        raise UnknownProject.new 'There is no project flagged as maintenance project on server and no target in request defined.'
      end
      maintenanceProject
    end

    # to check existens of a project (local or remote)
    def exists_by_name(name)
      dbp = where(name: name).first
      if dbp.nil?
        return true if find_remote_project(name)
        return false
      end
      unless check_access?(dbp)
        return false
      end
      return true
    end

    # to be obsoleted, this function is not throwing exceptions on problems
    # use get_by_name or exists_by_name instead
    def find_by_name(name, opts = {})
      arel = where(name: name)
      if opts[:select]
        arel = arel.select(opts[:select])
        opts.delete :select
      end
      raise "unsupport options #{opts.inspect}" if opts.size > 0
      dbp = arel.first
      return if dbp.nil?
      return unless check_access?(dbp)
      return dbp
    end

    def find_by_attribute_type( attrib_type )
      Project.joins(:attribs).where(:attribs => { :attrib_type_id => attrib_type.id })
    end

    def find_remote_project(name, skip_access=false)
      return nil unless name
      fragments = name.split(/:/)
      local_project = String.new
      remote_project = nil

      while !fragments.nil? && fragments.length > 1
        remote_project = [fragments.pop, remote_project].compact.join ':'
        local_project = fragments.join ':'
        logger.debug "checking local project #{local_project}, remote_project #{remote_project}"
        if skip_access
          # hmm calling a private class method is not the best idea..
          lpro = nil # FIXME2.4
        else
          lpro = Project.find_by_name(local_project, select: 'id,name,remoteurl')
          logger.debug "Found local project #{local_project} with remoteurl #{lpro[:remoteurl]}" if lpro
        end
        return lpro, remote_project unless lpro.nil? or !lpro.is_remote?
      end
      return nil
    end

  end

  def check_write_access!(ignoreLock=nil)
    return if Rails.env.test? and User.current.nil? # for unit tests

    # the can_create_check is inconsistent with package class check_write_access! check
    unless User.current.can_modify_project?(self, ignoreLock) || User.current.can_create_project?(self.name)
      raise WritePermissionError, "No permission to modify project '#{self.name}' for user '#{User.current.login}'"
    end
  end

  def find_linking_projects
      sql =<<-END_SQL
      SELECT prj.*
      FROM projects prj
      LEFT OUTER JOIN linked_projects lp ON lp.db_project_id = prj.id
      LEFT OUTER JOIN projects lprj ON lprj.id = lp.linked_db_project_id
      WHERE lprj.name = ?
      END_SQL
      # ACL TODO: should be check this or do we break functionality ?
      Project.find_by_sql [sql, self.name]
  end

  def is_locked?
    if @is_locked.nil?
      @is_locked = flags.where(flag: 'lock', status: 'enable').exists?
    end
    @is_locked
  end

  def is_unreleased?
    # returns true if NONE of the defined release targets are used
    self.repositories.includes(:release_targets).each do |repo|
      repo.release_targets.each do |rt|
        return false unless rt.trigger == "maintenance"
      end
    end
    true
  end

  # set defaults
  def init
    return unless new_record?
    self.type_id ||= DbProjectType.find_by_name('standard').id
  end

  def is_maintenance_release?
    self.project_type == 'maintenance_release'
  end

  def is_maintenance_incident?
    self.project_type == 'maintenance_incident'
  end

  def is_maintenance?
    self.project_type == 'maintenance'
  end

  def is_remote?
    !self.remoteurl.nil?
  end

  # NOTE: this is no permission check, should it be added ?
  def can_be_deleted?
    # check all packages
    self.packages.each do |pkg|
      begin
        pkg.can_be_deleted? # throws
      rescue Package::DeleteError => e
        e.packages.each do |p|
          if p.project != self
            raise DeleteError.new "Package #{self.name}/{pkg.name} can not be deleted as it's devel package of #{p.project.name}/#{p.name}"
          end
        end
      end
    end

    # do not allow to remove maintenance master projects if there are incident projects
    if self.project_type == 'maintenance'
      if MaintenanceIncident.find_by_maintenance_db_project_id self.id
        raise DeleteError.new 'This maintenance project has incident projects and can therefore not be deleted.'
      end
    end
    
  end

  def update_from_xml(xmlhash, force=nil)
    check_write_access!

    # check for raising read access permissions, which can't get ensured atm
    unless self.new_record? || self.disabled_for?('access', nil, nil)
      if FlagHelper.xml_disabled_for?(xmlhash, 'access')
        raise ForbiddenError.new
      end
    end
    unless self.new_record? || self.disabled_for?('sourceaccess', nil, nil)
      if FlagHelper.xml_disabled_for?(xmlhash, 'sourceaccess')
        raise ForbiddenError.new
      end
    end
    new_record = self.new_record?
    if ::Configuration.first.default_access_disabled == true and not new_record
      if self.disabled_for?('access', nil, nil) and not FlagHelper.xml_disabled_for?(xmlhash, 'access')
        raise ForbiddenError.new
      end
    end

    if self.name != xmlhash['name']
      raise SaveError, "project name mismatch: #{self.name} != #{xmlhash['name']}"
    end

    self.title = xmlhash.value('title')
    self.description = xmlhash.value('description')
    self.remoteurl = xmlhash.value('remoteurl')
    self.remoteproject = xmlhash.value('remoteproject')
    kind = xmlhash['kind'] || 'standard'
    project_type = DbProjectType.find_by_name(kind)
    raise SaveError.new("unable to find project kind '#{kind}'") unless project_type
    self.type_id = project_type.id

    # give us an id
    @commit_opts = { no_backend_write: 1 }
    self.save!

    update_linked_projects(xmlhash)
    parse_develproject(xmlhash)

    update_maintained_prjs_from_xml(xmlhash)
    update_relationships_from_xml(xmlhash)

    #--- update flag group ---#
    update_all_flags(xmlhash)
    if ::Configuration.first.default_access_disabled == true and new_record
      # write a default access disable flag by default in this mode for projects if not defined
      if xmlhash.elements('access').empty?
        self.flags.new(:status => 'disable', :flag => 'access')
      end
    end

    #--- update repository download settings ---#
    update_download_settings(xmlhash)

    #--- update repositories ---#
    update_repositories(xmlhash, force)

    #--- end update repositories ---#
    self.updated_at = Time.now
  end

  def update_repositories(xmlhash, force)
    fill_repo_cache
    xmlhash.elements('repository') do |repo|
      update_one_repository_without_path(repo)
    end
    xmlhash.elements('repository') do |repo|
      update_one_repository_add_pathes(repo)
    end

    # delete remaining repositories in @repocache
    @repocache.each do |name, object|
      logger.debug "offending repo: #{object.inspect}"
      unless force
        #find repositories that link against this one and issue warning if found
        list = PathElement.where(repository_id: object.id)
        check_for_empty_repo_list(list, "Repository #{self.name}/#{name} cannot be deleted because following repos link against it:")
        list = ReleaseTarget.where(target_repository_id: object.id)
        check_for_empty_repo_list(list, "Repository #{self.name}/#{name} cannot be deleted because following repos define it as release target:/")
      end
      logger.debug "deleting repository '#{name}'"
      self.repositories.destroy object
    end
    # save memory
    @repocache = nil
  end

  def fill_repo_cache
    @repocache = Hash.new
    self.repositories.each do |repo|
      @repocache[repo.name] = repo unless repo.remote_project_name
    end
  end

  def update_one_repository_add_pathes(repo)
    current_repo = self.repositories.find_by_name(repo['name'])

    #destroy all current pathelements
    current_repo.path_elements.destroy_all

    #recreate pathelements from xml
    position = 1
    repo.elements('path') do |path|
      link_repo = Repository.find_by_project_and_repo_name(path['project'], path['repository'])
      if path['project'] == self.name
        if path['repository'] == repo['name']
          raise SaveError, 'Using same repository as path element is not allowed'
        end
      end
      if !link_repo
        raise SaveError, "unable to walk on path '#{path['project']}/#{path['repository']}'"
      end
      current_repo.path_elements.new :link => link_repo, :position => position
      position += 1
    end

    current_repo.save!
  end

  def update_one_repository_without_path(repo)

    current_repo = @repocache[repo['name']]
    if current_repo
      logger.debug "modifying repository '#{repo['name']}'"
    else
      logger.debug "adding repository '#{repo['name']}'"
      current_repo = self.repositories.new(:name => repo['name'])
    end

    #--- repository flags ---#
    # check for rebuild configuration
    if !repo.has_key? 'rebuild' and current_repo.rebuild
      current_repo.rebuild = nil
    end
    if repo.has_key? 'rebuild'
      if repo['rebuild'] != current_repo.rebuild
        current_repo.rebuild = repo['rebuild']
      end
    end
    # check for block configuration
    if not repo.has_key? 'block' and current_repo.block
      current_repo.block = nil
    end
    if repo.has_key? 'block'
      if repo['block'] != current_repo.block
        current_repo.block = repo['block']
      end
    end
    # check for linkedbuild configuration
    if not repo.has_key? 'linkedbuild' and current_repo.linkedbuild
      current_repo.linkedbuild = nil
    end
    if repo.has_key? 'linkedbuild'
      if repo['linkedbuild'] != current_repo.linkedbuild
        current_repo.linkedbuild = repo['linkedbuild']
      end
    end
    #--- end of repository flags ---#

    #destroy all current releasetargets
    current_repo.release_targets.destroy_all

    #recreate release targets from xml
    repo.elements('releasetarget') do |rt|
      target_repo = Repository.find_by_project_and_repo_name(rt['project'], rt['repository'])
      unless target_repo
        raise SaveError.new("Unknown target repository '#{rt['project']}/#{rt['repository']}'")
      end
      unless target_repo.remote_project_name.nil?
        raise SaveError.new("Can not use remote repository as release target '#{rt['project']}/#{rt['repository']}'")
      end
      current_repo.release_targets.new :target_repository => target_repo, :trigger => rt['trigger']
    end

    #set host hostsystem
    if repo.has_key? 'hostsystem'
      hostsystem = Project.get_by_name repo['hostsystem']['project']
      target_repo = hostsystem.repositories.find_by_name repo['hostsystem']['repository']
      if repo['hostsystem']['project'] == self.name and repo['hostsystem']['repository'] == repo['name']
        raise SaveError, 'Using same repository as hostsystem element is not allowed'
      end
      unless target_repo
        raise SaveError, "Unknown target repository '#{repo['hostsystem']['project']}/#{repo['hostsystem']['repository']}'"
      end
      if target_repo != current_repo.hostsystem
        current_repo.hostsystem = target_repo
      end
    elsif current_repo.hostsystem
      current_repo.hostsystem = nil
    end

    current_repo.save! if current_repo.changed?

    #destroy architecture references
    logger.debug "delete all of #{current_repo.id}"
    RepositoryArchitecture.delete_all(['repository_id = ?', current_repo.id])

    position = 1
    repo.elements('arch') do |arch|
      unless Architecture.archcache.has_key? arch
        raise SaveError, "unknown architecture: '#{arch}'"
      end
      if current_repo.repository_architectures.where(architecture: Architecture.archcache[arch]).exists?
        raise SaveError, "double use of architecture: '#{arch}'"
      end
      current_repo.repository_architectures.create architecture: Architecture.archcache[arch], position: position
      position += 1
    end

    current_repo.save!

    @repocache.delete repo['name']
  end

  def update_download_settings(xmlhash)
    dlcache = Hash.new
    self.downloads.each do |dl|
      dlcache[dl.architecture.name] = dl
    end

    xmlhash.elements('download') do |dl|
      if dlcache.has_key? dl['arch']
        logger.debug "modifying download element, arch: #{dl['arch']}"
        cur = dlcache[dl['arch']]
      else
        logger.debug "adding new download entry, arch #{dl['arch']}"
        cur = self.downloads.create
      end
      cur.metafile = dl['metafile']
      cur.mtype = dl['mtype']
      cur.baseurl = dl['baseurl']
      raise SaveError, 'unknown architecture' unless Architecture.archcache.has_key? dl['arch']
      cur.architecture = Architecture.archcache[dl['arch']]
      cur.save!
      dlcache.delete dl['arch']
    end

    dlcache.each do |arch, object|
      logger.debug "remove download entry #{arch}"
      self.downloads.destroy object
    end
  end

  def parse_develproject(xmlhash)
    self.develproject = nil
    if devel = xmlhash['devel']
      if prj_name = devel['project']
        unless develprj = Project.get_by_name(prj_name)
          raise SaveError, "value of develproject has to be a existing project (project '#{prj_name}' does not exist)"
        end
        if develprj == self
          raise SaveError, 'Devel project can not point to itself'
        end
        self.develproject = develprj
      end
    end

    # cycle detection
    prj = self
    processed = {}
    while (prj and prj.develproject)
      prj_name = prj.name
      # cycle detection
      if processed[prj_name]
        str = ''
        processed.keys.each do |key|
          str = str + ' -- ' + key
        end
        raise CycleError.new "There is a cycle in devel definition at #{str}"
      end
      processed[prj_name] = 1
      prj = prj.develproject
      prj = self if prj && prj.id == self.id
    end

  end

  def update_linked_projects(xmlhash)
    position = 1
    #destroy all current linked projects
    self.linkedprojects.destroy_all

    #recreate linked projects from xml
    xmlhash.elements('link') do |l|
      link = Project.find_by_name(l['project'])
      if link.nil?
        if Project.find_remote_project(l['project'])
          self.linkedprojects.create(project: self,
                                     linked_remote_project_name: l['project'],
                                     position: position)
        else
          raise SaveError, "unable to link against project '#{l['project']}'"
        end
      else
        if link == self
          raise SaveError, 'unable to link against myself'
        end
        self.linkedprojects.create!(project: self,
                                    linked_db_project: link,
                                    position: position)
      end
      position += 1
    end
    position
  end

  def update_maintained_prjs_from_xml(xmlhash)
    # First check all current maintained project relations
    olds = {}
    self.maintained_projects.each{|mp| olds[mp.project.name]=mp}

    # Set this project as the maintenance project for all maintained projects found in the XML
    xmlhash.get('maintenance').elements('maintains') do |maintains|
      pn = maintains['project']
      next if olds.delete(pn)
      maintained_project = Project.get_by_name(pn)
      MaintainedProject.create(project: maintained_project, maintenance_project: self)
    end

    maintained_projects.delete(olds.values)
  end

  def check_for_empty_repo_list(list, error_prefix)
    return if list.empty?
    linking_repos = list.map { |x| x.repository.project.name+'/'+x.repository.name }.join "\n"
    raise SaveError.new (error_prefix + "\n" + linking_repos)
  end

  def write_to_backend
    logger.debug 'write_to_backend'
    # expire cache
    reset_cache
    @commit_opts ||= {}
    
    if CONFIG['global_write_through'] && !@commit_opts[:no_backend_write]
      login = @commit_opts[:login] || User.current.login
      query = { user: login }
      query[:comment] = @commit_opts[:comment] unless @commit_opts[:comment].blank?
      query[:requestid] = @commit_opts[:requestid] unless @commit_opts[:requestid].blank?
      query[:lowprio] = '1' if @commit_opts[:lowprio]
      Suse::Backend.put_source(self.source_path('_meta', query), to_axml)
    end
    @commit_opts = {}
  end

  def store(opts = {})
    @commit_opts = opts
    self.transaction do
      save!
      write_to_backend
    end
  end

  def reset_cache
    Rails.cache.delete('xml_project_%d' % id)
  end
  private :reset_cache # whoever changes the project, needs to store it too

  # for the HasAttributes mixing
  def attribute_url
    "/source/#{CGI.escape(self.name)}/_project/_attribute"
  end

  # step down through namespaces until a project is found, returns found project or nil
  def self.find_parent_for(project_name)
    name_parts = project_name.split(/:/)

    #project is not inside a namespace
    return nil if name_parts.length <= 1

    while name_parts.length > 1
      name_parts.pop
      if (p = Project.find_by_name name_parts.join(':'))
        #parent project found
        return p
      end
    end
    return nil
  end

  # convenience method for self.find_parent_for
  def find_parent
    self.class.find_parent_for self.name
  end

  def to_axml(opts={})
    Rails.cache.fetch('xml_project_%d' % id) do
      # CanRenderModel
      render_xml
    end
  end

  def to_axml_id
    return "<project name='#{::Builder::XChar.encode(name)}'/>\n"
  end

  # calculate enabled/disabled per repo/arch
  def flag_status(default, repo, arch, prj_flags, pkg_flags)
    ret = default
    expl = false

    flags = Array.new
    prj_flags.each do |f|
      flags << f if f.is_relevant_for?(repo, arch)
    end if prj_flags

    flags.sort! { |a,b| a.specifics <=> b.specifics }

    flags.each do |f|
      ret = f.status
      expl = f.is_explicit_for?(repo, arch)
    end

    flags = Array.new
    if pkg_flags
      pkg_flags.each do |f|
        flags << f if f.is_relevant_for?(repo, arch)
      end
      # in case we look at a package, the project flags are not explicit
      expl = false
    end
    flags.sort! { |a,b| a.specifics <=> b.specifics }
    flags.each do |f|
      ret = f.status
      expl = f.is_explicit_for?(repo, arch)
    end

    opts = Hash.new
    opts[:repository] = repo if repo
    opts[:arch] = arch if arch
    opts[:explicit] = '1' if expl
    ret = 'enable' if ret == :enabled
    ret = 'disable' if ret == :disabled
    # we allow to only check the return value
    return ret, opts
  end

  # give out the XML for all repos/arch combos
  def expand_flags(pkg = nil)
    ret = Hash.new
   
    repos = repositories.not_remote

    FlagHelper.flag_types.each do |flag_name|
      pkg_flags = nil
      flaglist = self.type_flags(flag_name)
      pkg_flags = pkg.type_flags(flag_name) if pkg
      flag_default = FlagHelper.default_for(flag_name)
      archs = Array.new
      flagret = Array.new
      unless %w(lock access sourceaccess).include?(flag_name)
        repos.each do |repo|
          flagret << flag_status(flag_default, repo.name, nil, flaglist, pkg_flags)
          repo.architectures.each do |arch|
            flagret << flag_status(flag_default, repo.name, arch.name, flaglist, pkg_flags)
            archs << arch.name
          end
        end
        archs.uniq.each do |arch|
          flagret << flag_status(flag_default, nil, arch, flaglist, pkg_flags)
        end
      end
      flagret << flag_status(flag_default, nil, nil, flaglist, pkg_flags)
      ret[flag_name] = flagret
    end
    ret
  end

  def can_be_released_to_project?(target_project)
    # is this package source going to a project which is specified as release target ?
    self.repositories.includes(:release_targets).each do |repo|
      repo.release_targets.each do |rt|
        return true if rt.target_repository.project == target_project
      end
    end
    false
  end

  def exists_package?(name, opts={})
    CacheLine.fetch([self, 'exists_package', name, opts], project: self.name, package: name) do
      if opts[:follow_project_links]
        pkg = self.find_package(name)
      else
        pkg = self.packages.find_by_name(name)
      end
      if pkg.nil?
        # local project, but package may be in a linked remote one
        opts[:allow_remote_packages] && Package.exists_on_backend?(name, self.name)
      else # if we could fetch the project, the package is fine accesswise
        true
      end
    end
  end

  # find a package in a project and its linked projects
  def find_package(package_name, check_update_project=nil, processed={})
    # cycle check in linked projects
    if processed[self]
      str = self.name
      processed.keys.each do |key|
        str = str + ' -- ' + key.name
      end
      raise CycleError.new "There is a cycle in project link defintion at #{str}"
      return nil
    end
    processed[self]=1

    # package exists in this project
    pkg = nil
    pkg = self.update_instance.packages.find_by_name(package_name) if check_update_project
    pkg = self.packages.find_by_name(package_name) if pkg.nil?
    return pkg if pkg and Package.check_access?(pkg)

    # search via all linked projects
    self.linkedprojects.each do |lp|
      if self == lp.linked_db_project
        raise CycleError.new 'project links against itself, this is not allowed'
        return nil
      end

      if lp.linked_db_project.nil?
        # We can't get a package object from a remote instance ... how shall we handle this ?
        pkg = nil
      else
        pkg = lp.linked_db_project.find_package(package_name, check_update_project, processed)
      end
      unless pkg.nil?
        return pkg if Package.check_access?(pkg)
      end
    end

    # no package found
    processed.delete(self)
    return nil
  end

  def expand_all_projects
    projects = [self]
    p_map = Hash.new
    projects.each { |i| p_map[i] = 1 } # existing projects map
    # add all linked and indirect linked projects
    self.linkedprojects.each do |lp|
      if lp.linked_db_project.nil?
        projects << lp.linked_remote_project_name
      else
        lp.linked_db_project.expand_all_projects.each do |p|
          unless p_map[p]
            projects << p
            p_map[p] = 1
          end
        end
      end
    end

    return projects
  end

  def expand_maintained_projects
    projects = []

    self.maintained_projects.each do |mp|
      mp.project.expand_all_projects.each do |p|
        projects << p
      end
    end

    return projects
  end


  # return array of [:name, :project_id] tuples
  def expand_all_packages
    p_map = Hash.new
    packages = self.packages.pluck(:name,:project_id)
    packages.each { |name, prjid| p_map[name] = 1 } # existing packages map
    # second path, all packages from indirect linked projects
    self.linkedprojects.each do |lp|
      if lp.linked_db_project.nil?
        # FIXME: this is a remote project
      else
        lp.linked_db_project.expand_all_packages.each do |name, prj_id|
          unless p_map[name]
            packages << [name, prj_id]
            p_map[name] = 1
          end
        end
      end
    end

    return packages
  end

  # return array of [:name, :package_id] tuples for all products
  # this function is making the products uniq
  def expand_all_products
    p_map = Hash.new
    products = Product.joins(:package).where("packages.project_id = ? and packages.name = '_product'", self.id).pluck(:name, :cpe, :package_id)
    products.each { |name, cpe, package_id| p_map[cpe] = 1 } # existing packages map
    # second path, all packages from indirect linked projects
    self.linkedprojects.each do |lp|
      if lp.linked_db_project.nil?
        # FIXME: this is a remote project
      else
        lp.linked_db_project.expand_all_products.each do |name, cpe, package_id|
          unless p_map[cpe]
            products << [name, cpe, package_id]
            p_map[cpe] = 1
          end
        end
      end
    end

    return products
  end

  # this is needed to displaying package and project names
  # packages is an array of :name, :db_project_id
  # return [package_name, project_name] where project_name is nil
  # if the project is local
  def map_packages_to_projects(packages)
    prj_names = Hash.new
    Project.where(id: packages.map { |a| a[1] }.uniq).pluck(:id, :name).each do |id, name|
      prj_names[id] = name
    end
    ret = []
    packages.each do |name, prj_id|
      if prj_id==self.id
        ret << [name, nil]
      else
        ret << [name, prj_names[prj_id]]
      end
    end
    ret
  end

  def map_products_to_packages(packages)
    ret = []
    packages.each do |p|
      package = Package.find_by_id p[2]
      ret << [p[0], p[1], package.project.name, package.updated_at.to_i]
    end
    ret
  end

  def project_type
    @project_type ||= DbProjectType.find(type_id).name
  end

  def set_project_type(project_type_name)
    check_write_access!

    mytype = DbProjectType.find_by_name(project_type_name)
    return false unless mytype
    self.type_id = mytype.id
    self.save!
    return true
  end

  def add_repository_with_targets(repoName, source_repo, add_target_repos = [])
    return if self.repositories.where(name: repoName).exists?
    trepo = self.repositories.create :name => repoName

    trepo.clone_repository_from(source_repo)

    trigger = nil # no trigger is set by default
    trigger = 'maintenance' if self.is_maintenance_incident?
    if add_target_repos.length > 0
      # add repository targets
      add_target_repos.each do |repo|
        trepo.release_targets.create(:target_repository => repo, :trigger => trigger)
      end
    end
  end

  def branch_to_repositories_from(project, pkg_to_enable, extend_names=nil)
    # shall we use the repositories from a different project?
    project = project.update_instance('OBS', 'BranchRepositoriesFromProject')
    skip_repos=[]
    a = project.find_attribute('OBS', 'BranchSkipRepositories') and skip_repos=a.values.map{|v| v.value}
    project.repositories.each do |repo|
      repoName = extend_names ? repo.extended_name : repo.name
      next if repo.is_local_channel?
      next if skip_repos.include? repoName
      pkg_to_enable.enable_for_repository(repoName) if pkg_to_enable
      next if self.repositories.find_by_name(repoName)

      # copy target repository when operating on a channel
      targets = repo.release_targets if (pkg_to_enable and pkg_to_enable.is_channel?)
      # base is a maintenance incident, take its target instead (kgraft case)
      targets = repo.release_targets if repo.project.is_maintenance_incident?

      target_repos = []
      target_repos = targets.map{|t| t.target_repository} if targets
      # or branch from official release project? release to it ...
      target_repos = [repo] if repo.project.is_maintenance_release?

      update_project = repo.project.update_instance
      if update_project != repo.project
        # building against gold master projects might happen (kgraft), but release
        # must happen to the right repos in the update project
        target_repos = Repository.find_by_project_and_path(update_project, repo)
      end

      self.add_repository_with_targets(repoName, repo, target_repos)
    end

    self.branch_copy_flags(project)

    if pkg_to_enable.is_channel?
      # explizit call for a channel package, so create the repos for it
      pkg_to_enable.channels.each do |channel|
        channel.add_channel_repos_to_project(pkg_to_enable)
      end
    end
  end

  def branch_copy_flags(project)
    # Copy the flags from the other project, adjusting them appropriately
    # for this one being a branch of it:
    #
    # - enable building
    # - disable 'publish' to save space and bandwidth
    #   (can be turned off for small installations)
    # - omit 'lock' or we cannot create packages
    disable_publish_for_branches = ::Configuration.first.disable_publish_for_branches
    project.flags.each do |f|
      next if %w(build lock).include?(f.flag)
      next if f.flag == 'publish' and disable_publish_for_branches
      # NOTE: it does not matter if that flag is set to enable or disable, so we do not check fro
      #       for same flag status here explizit
      next if self.flags.where(flag: f.flag, architecture: f.architecture, repo: f.repo).exists?

      self.flags.create(status: f.status, flag: f.flag, architecture: f.architecture, repo: f.repo)
    end

    if disable_publish_for_branches
      self.flags.create(:status => 'disable', :flag => 'publish') unless self.flags.find_by_flag_and_status( 'publish', 'disable' )
    end
  end

  def open_requests_with_project_as_source_or_target
    # Includes also requests for packages contained in this project
    rel = BsRequest.where(state: [:new, :review, :declined]).joins(:bs_request_actions)
    rel = rel.where('bs_request_actions.source_project = ? or bs_request_actions.target_project = ?', self.name, self.name)
    return BsRequest.where(id: rel.pluck('bs_requests.id'))
  end

  def open_requests_with_by_project_review
    # Includes also by_package reviews for packages contained in this project
    rel = BsRequest.where(state: [:new, :review])
    rel = rel.joins(:reviews).where("reviews.state = 'new' and reviews.by_project = ? ", self.name)
    return BsRequest.where(id: rel.pluck('bs_requests.id'))
  end

  # list only the repositories that have a target project in the build path
  # the function uses the backend for informations (TODO)
  def repositories_linking_project(tproj)
    tocheck_repos = Array.new

    targets = bsrequest_repos_map(tproj.name)
    sources = bsrequest_repos_map(self.name)
    sources.each do |key, value|
      if targets.has_key?(key)
        tocheck_repos << sources[key]
      end
    end

    tocheck_repos.flatten!
    tocheck_repos.uniq
  end

  # called either directly or from delayed job
  def do_project_copy( params )
    # set user if nil, needed for delayed job in Package model
    User.current ||= User.find_by_login(params[:user])

    check_write_access!

    # copy entire project in the backend
    begin
      path = "/source/#{URI.escape(self.name)}"
      path << Suse::Backend.build_query_from_hash(params, [:cmd, :user, :comment, :oproject, :withbinaries, :withhistory, :makeolder, :noservice])
      Suse::Backend.post path, nil
    rescue ActiveXML::Transport::Error => e
      logger.debug "copy failed: #{e.summary}"
      # we need to check results of backend in any case (also timeout error eg)
    end

    # restore all package meta data objects in DB
    backend_pkgs = Collection.find :package, :match => "@project='#{self.name}'"
    backend_pkgs.each('package') do |package|
      pname = package.value('name')
      path = "/source/#{URI.escape(self.name)}/#{pname}/_meta"
      p = self.packages.where(name: pname).first_or_initialize
      p.update_from_xml(Xmlhash.parse(Suse::Backend.get(path).body))
      p.save! # do not store
    end
    packages.each { |p| p.sources_changed }
  end

  # called either directly or from delayed job
  def do_project_release( params )
    def my_not_equal(a, b)
       a and a != b
    end

    User.current ||= User.find_by_login(params[:user])

    packages.each do |pkg|
      next if pkg.name == "_product" # will be handled via _product:*
      pkg.project.repositories.each do |repo|
        next if my_not_equal(params[:repository], repo.name)
        repo.release_targets.each do |releasetarget|
          next if my_not_equal(params[:targetproject], releasetarget.target_repository.project.name)
          next if my_not_equal(params[:targetreposiory], releasetarget.target_repository.name)
          # release source and binaries
          # permission checking happens inside this function
          release_package(pkg, releasetarget.target_repository, pkg.name, repo, nil, params[:setrelease], true)
        end
      end
    end
  end

  after_save do
    Rails.cache.delete "bsrequest_repos_map-#{self.name}"
    @is_locked = nil
  end

  def bsrequest_repos_map(project)
    Rails.cache.fetch("bsrequest_repos_map-#{project}", expires_in: 2.hours) do
      ret = Hash.new
      uri = "/getprojpack?project=#{CGI.escape(project.to_s)}&nopackages&withrepos&expandedrepos"
      begin
        body = Suse::Backend.get(uri).body
        xml = Xmlhash.parse body
      rescue ActiveXML::Transport::Error
        return ret
      end

      xml.get('project').elements('repository') do |repo|
        repo.elements('path') do |path|
          ret[path['project']] ||= Array.new
          ret[path['project']] << repo
        end
      end

      ret
    end
  end

  private :bsrequest_repos_map


  def self.valid_name?(name)
    return false unless name.kind_of? String
    # this length check is duplicated but useful for other uses for this function
    return false if name.length > 200 || name.blank?
    return false if name =~ %r{^[_\.]} 
    return false if name =~ %r{::}
    return true if name =~ /\A\w[-+\w\.:]*\z/
    return false
  end

  def valid_name
    errors.add(:name, 'is illegal') unless Project.valid_name?(self.name)
  end

  # updates packages automatically generated in the backend after submitting a product file
  def update_product_autopackages
    backend_pkgs = Collection.find :id, :what => 'package', :match => "@project='#{self.name}' and starts-with(@name,'_product:')"
    b_pkg_index = backend_pkgs.each(:package).inject(Hash.new) {|hash,elem| hash[elem.value(:name)] = elem; hash}
    frontend_pkgs = self.packages.where("`packages`.name LIKE '_product:%'")
    f_pkg_index = frontend_pkgs.inject(Hash.new) {|hash,elem| hash[elem.name] = elem; hash}

    all_pkgs = [b_pkg_index.keys, f_pkg_index.keys].flatten.uniq

    all_pkgs.each do |pkg|
      if b_pkg_index.has_key?(pkg) and not f_pkg_index.has_key?(pkg)
        # new autopackage, import in database
        p = self.packages.new(name: pkg)
        p.update_from_xml(Xmlhash.parse(b_pkg_index[pkg].dump_xml))
        p.store
      elsif f_pkg_index.has_key?(pkg) and not b_pkg_index.has_key?(pkg)
        # autopackage was removed, remove from database
        f_pkg_index[pkg].destroy
      end
    end
  end

  def request_ids_by_class(useroles=true)
    roles = %w(reviewer) if useroles
    rel = BsRequestCollection.new(project: name, states: %w(review), roles: roles )
    reviews = rel.ids

    roles = %w(target) if useroles
    rel = BsRequestCollection.new(project: name, states: %w(new), roles: roles )
    targets = rel.ids

    roles = %w(source) if useroles
    rel = BsRequestCollection.new(project: name, states: %w(new), roles: roles, types: %w(maintenance_incident))
    incidents = rel.ids

    if is_maintenance?
      roles = %w(source) if useroles
      rel = BsRequestCollection.new(project: name, states: %w(new), roles: roles, types: %w(maintenance_release), subprojects: true)
      maintenance_release = rel.ids
    else
      maintenance_release = []
    end

    { 'reviews' => reviews, 'targets' => targets, 'incidents' => incidents, 'maintenance_release' => maintenance_release }
  end

  # for the clockworkd - called delayed
  def update_packages_if_dirty
    packages.dirty_backend_package.each do |p|
      p.update_if_dirty
    end
  end

  # Returns a list of pairs (full name, short name) for each parent
  def self.parent_projects(project_name)
    atoms = project_name.split(':')
    projects = []
    unused = 0

    for i in 1..atoms.length do
      p = atoms.slice(0, i).join(':')
      r = atoms.slice(unused, i - unused).join(':')
      if Project.where(name: p).exists? # ignore remote projects here
        projects << [p, r]
        unused = i
      end
    end
    projects
  end

  def unlock(comment=nil)
    if self.is_maintenance_incident?
      rel = BsRequest.where(state: [:new, :review, :declined]).joins(:bs_request_actions)
      rel = rel.where(bs_request_actions: { type: 'maintenance_release', source_project: self.name})
      if rel.exists?
        raise OpenReleaseRequest.new "Unlock of maintenance incident #{} is not possible, because there is a running release request: #{rel.first.id}"
      end
    end

    p = { :comment => comment }

    f = self.flags.find_by_flag_and_status('lock', 'enable')
    raise ProjectNotLocked.new "project '#{@project.name}' is not locked" unless f

    self.transaction do
      self.flags.delete(f)
      self.store(p)

      # maintenance incidents need special treatment
      if self.is_maintenance_incident?
        # reopen all release targets
        self.repositories.each do |repo|
          repo.release_targets.each do |releasetarget|
            releasetarget.trigger = 'maintenance'
            releasetarget.save!
          end
        end
        self.store(p)

        # ensure higher build numbers for re-release
        Suse::Backend.post "/build/#{URI.escape(self.name)}?cmd=wipe", nil
      end
    end

    update_packages_if_dirty
  end

  def unlock_by_request(id)
    f = self.flags.find_by_flag_and_status('lock', 'enable')
    if f
      self.flags.delete(f)
      self.store(comment: "Request #{} got revoked", request: id, lowprio: 1)
    end
  end

  def build_succeeded?(repository = nil)
    states = {}
    repository_states = {}

    br = Buildresult.find(:project => self.name, :view => 'summary')
    # no longer there?
    return false unless br

    br.each('result') do |result|

      if repository && result.value(:repository) == repository
        repository_states[repository] ||= {}
        result.each('summary') do |summary|
          summary.each('statuscount') do |statuscount|
            repository_states[repository][statuscount.value('code')] ||= 0
            repository_states[repository][statuscount.value('code')] += statuscount.value('count').to_i()
          end
        end
      else
        result.each('summary') do |summary|
          summary.each('statuscount') do |statuscount|
            states[statuscount.value('code')] ||= 0
            states[statuscount.value('code')] += statuscount.value('count').to_i()
          end
        end
      end
    end
    if repository && repository_states.has_key?(repository)
      return false if repository_states[repository].empty? # No buildresult is bad
      repository_states[repository].each do |state, count|
        return false if %w(broken failed unresolvable).include?(state)
      end
    else
      return false unless states.empty? # No buildresult is bad
      states.each do |state, count|
        return false if %w(broken failed unresolvable).include?(state)
      end
    end
    return true
  end

  def find_incident_issues
    linkdiff = pkg.linkdiff()
    if linkdiff && linkdiff.has_element?('issues')
      linkdiff.issues.each(:issue) do |issue|
        release_targets_ng[rt_name][:package_issues][issue.value('label')] = issue

        release_targets_ng[rt_name][:package_issues_by_tracker][issue.value('tracker')] ||= []
        release_targets_ng[rt_name][:package_issues_by_tracker][issue.value('tracker')] << issue
      end
    end
  end

  # Returns maintenance incidents by type for current project (if any)
  def maintenance_incidents
    all = Project.where('projects.name like ?', "#{self.name}:%").distinct.where(type_id: DbProjectType.find_by_name('maintenance_incident'))
    all = all.joins(:repositories).joins('JOIN release_targets rt on rt.repository_id=repositories.id')
    all.where('rt.trigger = "maintenance"')
  end

  def release_targets_ng
    # First things first, get release targets as defined by the project, err.. incident. Later on we
    # magically find out which of the contained packages, err. updates are build against those release
    # targets.
    release_targets_ng = {}
    self.repositories.each do |repo|
      repo.release_targets.each do |rt|
        release_targets_ng[rt.target_repository.project.name] = {:reponame => repo.name, :packages => [], :patchinfo => nil, :package_issues => {}, :package_issues_by_tracker => {}}
      end
    end

    # One catch, currently there's only one patchinfo per incident, but things keep changing every
    # other day, so it never hurts to have a look into the future:
    global_patchinfo = nil
    self.packages.each do |pkg|
      if pkg.is_patchinfo?
        # Global 'patchinfo' without specific release target:
        global_patchinfo = pkg.patchinfo
        next
      end

      rt_name = pkg.name.split('.', 2).last
      next unless rt_name
      if pkg.is_patchinfo?
        # We found a patchinfo that is specific to (at least) one release target!
        pi = pkg.patchinfo
        begin
          release_targets_ng[rt_name][:patchinfo] = pi
        rescue
          #TODO FIXME ARGH: API/backend need some work to support this better.
          # Until then, multiple patchinfos are problematic
        end
      else
        # Here we try hard to find the release target our current package is build for:
        found = false
        # Stone cold map'o'rama of package.$SOMETHING with package/build/enable/@repository=$ANOTHERTHING to
        # project/repository/releasetarget/@project=$YETSOMETINGDIFFERENT. Piece o' cake, eh?
        pkg.flags.where(flag: :build, status: 'enable').each do |enable|
          if enable.repo
            release_targets_ng.each do |rt_key, rt_value|
              if rt_value[:reponame] == enable.repo
                rt_name = rt_key # Save for re-use
                found = true
                break
              end
            end
          end
        end
        if !found
          # Package only contains sth. like: <build><enable repository="standard"/></build>
          # Thus we asume it belongs to the _only_ release target:
          rt_name = release_targets_ng.keys.first
        end
      end

      # Build-disabled packages can't be matched to release targets....
      if found
        # Let's silently hope that an incident newer introduces new (sub-)packages....
        release_targets_ng[rt_name][:packages] << pkg
      end
    end

    if global_patchinfo
      release_targets_ng.each do |rt_name, rt|
        rt[:patchinfo] = global_patchinfo
      end
    end
    return release_targets_ng
  end

  def self.source_path(project, file = nil, opts = {})
    path = "/source/#{URI.escape(project)}"
    path += "/#{URI.escape(file)}" unless file.blank?
    path += '?' + opts.to_query unless opts.blank?
    path
  end

  def source_path(file = nil, opts = {})
    Project.source_path(self.name, file, opts)
  end

  def source_file(file, opts = {})
    Suse::Backend.get(source_path(file, opts)).body
  end

  def api_obj
    self
  end

  def to_s
    name
  end

end
