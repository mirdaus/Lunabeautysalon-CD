pipeline {
    agent any

    parameters {
        string(
            name: 'IMAGE_TAG',
            defaultValue: 'latest',
            description: 'ECR image tag to deploy'
        )
    }

    environment {
        // Required for Homebrew tools on Apple Silicon Mac
        PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${env.PATH}"

        AWS_REGION     = 'us-east-1'
        AWS_ACCOUNT_ID = '484908302072'

        ECR_REPOSITORY = 'lunabeautysalon'

        ECS_CLUSTER    = 'lunabeautysalon'
        ECS_SERVICE    = 'lunabeautysalon-service'
        TASK_FAMILY    = 'lunabeautysalon'

        // Must match the container name inside ECS Task Definition
        CONTAINER_NAME = 'lunabeautysalon'
    }

    stages {

        stage('Verify Environment') {
            steps {
                sh '''
                    echo "======================================"
                    echo "Checking Jenkins Environment"
                    echo "======================================"

                    echo "PATH:"
                    echo "$PATH"

                    echo ""
                    echo "AWS CLI:"
                    which aws
                    /opt/homebrew/bin/aws --version

                    echo ""
                    echo "JQ:"
                    which jq
                    /opt/homebrew/bin/jq --version
                '''
            }
        }

        stage('Verify AWS Connection') {
            steps {
                sh '''
                    echo "Checking AWS authentication..."

                    /opt/homebrew/bin/aws sts get-caller-identity \
                        --region $AWS_REGION
                '''
            }
        }

        stage('Deployment Information') {
            steps {
                sh '''
                    echo "======================================"
                    echo "Luna Beauty Salon CD"
                    echo "======================================"

                    echo "AWS Account: $AWS_ACCOUNT_ID"
                    echo "Region: $AWS_REGION"
                    echo "Cluster: $ECS_CLUSTER"
                    echo "Service: $ECS_SERVICE"
                    echo "Task Family: $TASK_FAMILY"
                    echo "Container: $CONTAINER_NAME"
                    echo "Image Tag: $IMAGE_TAG"

                    echo "======================================"
                '''
            }
        }

        stage('Get Current Task Definition') {
            steps {
                sh '''
                    echo "Getting current ECS Task Definition..."

                    /opt/homebrew/bin/aws ecs describe-task-definition \
                        --task-definition $TASK_FAMILY \
                        --region $AWS_REGION \
                        --query taskDefinition \
                        > current-task-definition.json

                    echo "Current task definition downloaded."
                '''
            }
        }

        stage('Prepare New Task Definition') {
            steps {
                sh '''
                    IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$IMAGE_TAG"

                    echo "New Docker image:"
                    echo "$IMAGE_URI"

                    /opt/homebrew/bin/jq \
                      --arg IMAGE "$IMAGE_URI" \
                      --arg CONTAINER "$CONTAINER_NAME" \
                      '
                      .containerDefinitions |= map(
                          if .name == $CONTAINER
                          then .image = $IMAGE
                          else .
                          end
                      )
                      |
                      del(
                          .taskDefinitionArn,
                          .revision,
                          .status,
                          .requiresAttributes,
                          .compatibilities,
                          .registeredAt,
                          .registeredBy
                      )
                      ' current-task-definition.json \
                      > new-task-definition.json

                    echo "New task definition prepared."

                    echo "Image inside new task definition:"
                    /opt/homebrew/bin/jq '.containerDefinitions[] | {name,image}' \
                        new-task-definition.json
                '''
            }
        }

        stage('Register New Task Definition') {
            steps {
                script {

                    env.NEW_TASK_DEFINITION = sh(
                        script: '''
                            /opt/homebrew/bin/aws ecs register-task-definition \
                                --region $AWS_REGION \
                                --cli-input-json file://new-task-definition.json \
                                --query 'taskDefinition.taskDefinitionArn' \
                                --output text
                        ''',
                        returnStdout: true
                    ).trim()

                    echo "New Task Definition:"
                    echo "${env.NEW_TASK_DEFINITION}"
                }
            }
        }

        stage('Update ECS Service') {
            steps {
                sh '''
                    echo "Updating ECS Service..."

                    /opt/homebrew/bin/aws ecs update-service \
                        --cluster $ECS_CLUSTER \
                        --service $ECS_SERVICE \
                        --task-definition $NEW_TASK_DEFINITION \
                        --region $AWS_REGION \
                        --query 'service.{Service:serviceName,TaskDefinition:taskDefinition,Status:status}' \
                        --output table
                '''
            }
        }

        stage('Wait for Deployment') {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    sh '''
                        echo "Waiting for ECS service to become stable..."

                        /opt/homebrew/bin/aws ecs wait services-stable \
                            --cluster $ECS_CLUSTER \
                            --services $ECS_SERVICE \
                            --region $AWS_REGION

                        echo "ECS Service is stable."
                    '''
                }
            }
        }

        stage('Verify Deployment') {
            steps {
                sh '''
                    echo "======================================"
                    echo "Deployment Result"
                    echo "======================================"

                    /opt/homebrew/bin/aws ecs describe-services \
                        --cluster $ECS_CLUSTER \
                        --services $ECS_SERVICE \
                        --region $AWS_REGION \
                        --query 'services[0].{
                            Status:status,
                            Running:runningCount,
                            Desired:desiredCount,
                            TaskDefinition:taskDefinition
                        }' \
                        --output table
                '''
            }
        }
    }

    post {

        success {
            echo '======================================'
            echo 'DEPLOYMENT SUCCESSFUL!'
            echo 'Luna Beauty Salon is deployed to ECS.'
            echo '======================================'
        }

        failure {
            echo '======================================'
            echo 'DEPLOYMENT FAILED'
            echo 'Check Jenkins Console Output and ECS Events.'
            echo '======================================'
        }

        always {
            sh '''
                rm -f current-task-definition.json
                rm -f new-task-definition.json
            '''
        }
    }
}
