@{
    IncludeRules = @(
        'PSUseCompatibleSyntax',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1')
        }
    }
}
