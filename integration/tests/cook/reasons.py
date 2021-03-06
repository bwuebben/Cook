# Named constants for failure reason codes from cook or mesos.
# See scheduler/src/cook/mesos/schema.clj for the reason code names.
MAX_RUNTIME_EXCEEDED = 2003
EXECUTOR_UNREGISTERED = 6002
CMD_NON_ZERO_EXIT = 99003


# Named constants for unscheduled job reason strings from cook or fenzo.
UNDER_INVESTIGATION = 'The job is now under investigation. Check back in a minute for more details!'
COULD_NOT_PLACE_JOB = 'The job couldn\'t be placed on any available hosts.'
