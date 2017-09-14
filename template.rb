# template.rb
add_source "https://gems.ruby-china.org"

insert_into_file '.gitignore', :after => "# Ignore all logfiles and tempfiles." do
  <<-CODE
\nconfig/database.yml
config/secrets.yml
config/application.yml
.vscode/
  CODE
end
  
insert_into_file 'Gemfile', "\nruby '2.3.1'\n", after: "source 'https://rubygems.org'\n"
  
gem_group :development, :test do
  gem 'factory_girl_rails'
  gem 'brakeman'
  gem 'bundler-audit'
  gem "rspec-rails"
  gem "pre-commit", require: false
  gem 'rubocop'
  gem 'annotate'
end

file 'docker_web_run.sh', <<-CODE
#!/bin/bash
#文件的换行模式要选UNIX风格的LF,不然脚本执行会出错!

REDIS_HOST=redis
echo "export REDIS_HOST=${REDIS_HOST}" >> ${HOME}/.bashrc

#如果读不到环境变量RUN_CONTEXT，默认设为dev
if [ -z $RUN_CONTEXT ]; then
    RUN_CONTEXT='dev'
    echo "export RUN_CONTEXT=${RUN_CONTEXT}" >> ${HOME}/.bashrc
fi

#使设置的环境变量即时生效
source ~/.bashrc

#开发环境
if [ "$RUN_CONTEXT" = "dev" ]; then
    #设置ssh密码
    echo "root:123456" | chpasswd
    #启动sshd
    /usr/sbin/sshd
    #启动cron
    /etc/init.d/cron start
    #执行rake任务
    bundle exec rake db:migrate
    #开启rails定时任务
    #whenever -w
    #启动rails
    #echo `bundle exec rails s -b 0.0.0.0 -p 3000`
    passenger start --environment development --port 3000

#预发布环境
elif [ "$RUN_CONTEXT" = "pre_prod" ]; then
    echo "root:Q!W@E#!@&" | chpasswd
    #设置ssh密码,密码为环境变量ROOT_PASSWD的值,如果环境变量ROOT_PASSWD没有设,则指定一个默认密码
    if [ $ROOT_PASSWD ]; then
        echo "root:$ROOT_PASSWD" | chpasswd
    fi
    #启动sshd
    /usr/sbin/sshd
    #启动rsyslog
    /etc/init.d/rsyslog start
    #启动cron
    /etc/init.d/cron start
    #执行assets:precompile
    RAILS_ENV=pre_production bundle exec rake assets:precompile
    #执行db:migrate
    RAILS_ENV=pre_production bundle exec rake db:migrate
    #开启rails定时任务
    #whenever -w
    #启动rails
    passenger start --environment pre_production --port 80

#生产环境
elif [ "$RUN_CONTEXT" = "prod" ]; then
    echo "root:Q!W@E#!@&" | chpasswd
    #设置ssh密码,密码为环境变量ROOT_PASSWD的值,如果环境变量ROOT_PASSWD没有设,则指定一个默认密码
    if [ $ROOT_PASSWD ]; then
        echo "root:$ROOT_PASSWD" | chpasswd
    fi
    #启动sshd
    /usr/sbin/sshd
    #启动rsyslog
    /etc/init.d/rsyslog start
    #启动cron
    /etc/init.d/cron start
    #执行assets:precompile
    RAILS_ENV=production bundle exec rake assets:precompile
    #执行db:migrate
    RAILS_ENV=production bundle exec rake db:migrate

    #启动rails
    passenger start
else
    echo "unknown RUN_CONTEXT:${RUN_CONTEXT}"
fi

CODE

file 'Dockerfile', <<-CODE
FROM daocloud.io/skio_dep/rails_5.1.4:v1_onbuild

CMD /bin/bash docker_web_run.sh
CODE

file 'docker-compose.yml', <<-CODE
web:
image: daocloud.io/skio_dep/#{app_name}:latest
restart: always
links:
- redis
ports:
- '80'
- '22'
volumes:
- /apps/#{app_name}/rails_log:/rails_app/log
environment:
- REDIS_HOST=redis
- RAILS_ENV=pre_production
- VIRTUAL_HOST=1.com
- SECRET_KEY_BASE=123456

CODE

file 'Passengerfile.json', <<-CODE
{
  "environment": "production",
  "port": 80,
  "friendly_error_pages": true,
  "daemonize": false
}

CODE

file '.gitlab-ci.yml', <<-CODE
image: daocloud.io/skio_dep/rails_5.1.4:v1

services:
  - daocloud.io/library/mysql:5.6

variables:
  MYSQL_DATABASE: #{app_name}_test
  MYSQL_ALLOW_EMPTY_PASSWORD: 'yes'

stages:
  - audit
  - style
  - test
  - dockerize


.setup_template: &setup_template
  before_script:
    - bash /root/setup_suites/script/set_up.sh
    - cp config/secrets.yml.example config/secrets.yml
    - cp config/database.yml.ci config/database.yml
    - ruby -v
    - which ruby
    - gem sources --add https://gems.ruby-china.org/ --remove https://rubygems.org/
    - gem sources -l
    - gem install bundler --no-ri --no-rdoc
    - bundle config mirror.https://rubygems.org https://gems.ruby-china.org
    - bundle install --jobs $(nproc)  "${FLAGS[@]}" --path=/cache/bundler

.dockerize: &dockerize
  image: daocloud.io/library/docker:latest
  stage: dockerize
  before_script:
    - docker login -u $DAOCLOUD_USERNAME -p $DAOCLOUD_PASSWORD  daocloud.io
    - docker build --pull -t $CONTAINER_IMAGE .
    - docker push $CONTAINER_IMAGE
  allow_failure: false


####################################################################################################
# audit
bundler-audit:
  <<: *setup_template
  stage: audit
  script:
    - bin/bundle-audit update
    - bin/bundle-audit check
  allow_failure: true
  except:
    - master
    - production
    - tags
brakeman:
  <<: *setup_template
  stage: audit
  script:
    - bin/brakeman
  allow_failure: true
  except:
      - master
      - production
      - tags

####################################################################################################
# style
rubocop:
  <<: *setup_template
  stage: style
  script:
    - bundle exec rubocop
  except:
    - production
    - tags

rails_best_practices:
  <<: *setup_template
  stage: style
  script:
    - bin/rails_best_practices
  allow_failure: true
  except:
    - master
    - production
    - tags

####################################################################################################
# test
rspec:
  <<: *setup_template
  stage: test
  script:
    - bin/rake db:setup RAILS_ENV=test
    - bin/rspec
  except:
    - tags

####################################################################################################
# dockerize
deploy to stage:
  <<: *dockerize
  environment:
    name: stage
    url: http://#{app_name}.com
  script:
      - echo 'Easy, cowboy~'
  only:
    - master
  variables:
    DAOCLOUD_APP_ID: 123344444 
    RELEASE_NAME: production-stage-$CI_BUILD_REF-$GITLAB_USER_ID
    CONTAINER_IMAGE: daocloud.io/skio_dep/#{app_name}_preproduction:$CI_BUILD_REF-$GITLAB_USER_ID


deploy production to stage:
  <<: *dockerize
  environment:
    name: stage
    url: http://#{app_name}.com
    
  script:
      - echo 'Easy, cowboy~'
  only:
    - production
  except:
    - tags
  variables:
    DAOCLOUD_APP_ID: 
    RELEASE_NAME: production-stage-$CI_BUILD_REF-$GITLAB_USER_ID
    CONTAINER_IMAGE: daocloud.io/skio_dep/#{app_name}_preproduction:$CI_BUILD_REF-$GITLAB_USER_ID

build production docker image:
  <<: *dockerize
  script:
    - echo 'Easy, cowboy~'
  only:
    - tags
  except:
    - branches
  variables:
    CONTAINER_IMAGE: daocloud.io/skio_dep/#{app_name}:production-$CI_COMMIT_TAG-$GITLAB_USER_ID
CODE

file '.rubocop.yml', <<-CODE
inherit_from: .rubocop_todo.yml

AllCops:
  Exclude:
    - 'vendor/**/*'
    - 'db/*'
    - 'db/fixtures/**/*'
    - 'tmp/**/*'
    - 'bin/**/*'
    - 'generator_templates/**/*'
    - 'db/migrate/*'
    - 'config/**/*'
    - 'spec/*'
    - 'Gemfile'

Metrics/LineLength:
  Max: 100
Documentation:
  Enabled: false
CODE

file '.rubocop_todo.yml', <<-CODE
CODE

after_bundle do
  git :init
  remove_dir "./test"
  rails_command "g rspec:install"
  generate(:controller, "welcome", "index")
  route "root to: 'welcome#index'"
  rails_command("db:migrate") 
  copy_file './config/database.yml', './config/database.yml.example'
  copy_file './config/secrets.yml', './config/secrets.yml.example'
  copy_file './config/environments/production.rb', './config/environments/pre_production.rb'
end