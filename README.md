# General Understanding / Key Points

## **The Core Problem**
- **Issue**: Tasks cannot write or modify their arguments.
- **Objective**: Allow tasks to modify function arguments while enforcing correct usage to avoid parallelism issues.

## **Solution Overview**
Each task will describe its relation to its arguments:
1. **Read-only**: Arguments used only for reading their content.
2. **Write-only**: Arguments used only for writing (no reading needed).
3. **Read-Write**: Arguments used for both reading and storing results.

---

# **Implementation Overview**

## **DataDepsTaskQueue**
A queue, `DataDepsTaskQueue`, is created to manage all tasks to be executed. It consists of:

- **`upper_queue`**: Pointer/reference to the original tasks queue.
- **`seen_tasks`**: Tracks tasks that have been processed or "seen."
  - Each seen task is defined as:
    - **`DTaskSpec`**: Contains task details such as:
      - Function to execute.
      - Arguments and their values.
    - **`DTask`**: The original task represented by:
      - Task ID.
      - `ThunkFuture`: Delays evaluation of the task until its dependencies are met.
      - Metadata for task management.
      - Cleanup handlers.

### **`ThunkFuture`**
- A wrapper around `Future`.
- Used to delay task execution until conditions (e.g., dependencies) are satisfied.

---

# **Additional Components**

### **Traversal and Scheduling**
- **`traversal`**: Defines how the tasks are chosen for execution.
- **`scheduler`**: Determines the scheduling technique for task assignment.

### **Aliasing**
Indicates whether tasks can share memory when accessing the same argument:
- **No Aliasing**: Copies of the data are created for safe processing.

---

# **Tracking Task Aliases**
For each piece of data, we track:
1. **Original Location**: Where the data was first created/stored.
2. **Current Location**: Data may move (e.g., CPU → GPU).
3. **Readers**: All tasks currently reading the data.
4. **Owner**: The current task with write/modify access.
5. **Overlaps**: Any sub-views or parts of the data being accessed by other tasks.

---

# **Identifying Task Dependencies (Aliasing Focus)**
For each task:
1. **Resolve Dependencies**: Determine data dependencies (arguments) required for execution.
2. **Access Patterns**:
   - Identify whether the argument is:
     - `In`: Read-only.
     - `Out`: Write-only.
     - `InOut`: Read-Write.
3. **Alias Detection**:
   - Identify other tasks sharing access to the same memory (full or partial).

---

## **Order of Execution in Deeper Details**

1. **Caller Function Initialization**:
   - The caller function, which contains the parallel logic to be executed, uses Dagger for task parallelization.
   - Arguments in the caller function are decorated with access patterns (`In`, `Out`, or `InOut`).

2. **Using `Dagger.spawn_datadeps`**:
   - The caller function starts by calling `Dagger.spawn_datadeps` and passes the code/logic to be executed as a lambda function parameter.

3. **Task Queue Initialization**:
   - Inside `wait_all`, the following steps occur:
     - The system creates the **upper_queue**, which holds tasks (`DTask`) that are ready for execution.
     - This queue is stored as a configuration within the system for reuse.
     - The `f` function (which refers to the `spawn_datadeps` logic) begins execution.

4. **Creating `DataDepsTaskQueue`**:
   - As part of the `spawn_datadeps` execution:
     - A `DataDepsTaskQueue` instance is created.
     - The `upper_queue` initialized earlier is passed as the `upper_queue` argument when creating the `DataDepsTaskQueue` instance.

5. **Original Function Logic Execution**:
   - After creating the `DataDepsTaskQueue`, the system starts executing the logic of the original caller function that invoked `spawn_datadeps`.
   - The number of tasks to be created is determined by the number of calls to the `@spawn` macro within the caller function.

6. **Task Creation with `@spawn`**:
   - Each `@spawn` macro triggers the following sequence:
     - The `spawn` function is called.
     - The `spawn` function creates:
       - A `DTaskSpec`, which encapsulates the task's function, arguments, and metadata.
       - A `DTask`, which includes task-related information like task ID, future results (`ThunkFuture`), and clean-up metadata.
     - The task is then enqueued in the `DataDepsTaskQueue`.

7. **Task Enqueue**:
   - All created tasks are enqueued into `queue.seen_tasks`, which belongs to the `DataDepsTaskQueue` instance.

8. **Task Allocation and Scheduling**:
   - Once all tasks are enqueued, the `distribute_tasks` function is called to initiate task allocation and scheduling.
   - This function ensures:
     - Tasks are assigned to appropriate processors.
     - Dependencies between tasks are resolved.

---

### **Execution Process in Detail**

1. **Traversal and Execution**:
   - By default, tasks are executed in an in-order traversal, meaning they are executed in the same order they were enqueued.

2. **Logic of `spawn_datadeps`**:
   - The `f` function (logic of `spawn_datadeps`) starts executing the original caller's logic.
   - For every `@spawn` encountered, the following occurs:
     - A `DTaskSpec` and its accompanying `DTask` are created.
     - These tasks are enqueued into `queue.seen_tasks` for later execution.

3. **Initiating Execution with `distribute_tasks`**:
   - After all tasks are placed in the queue, the actual scheduling/ordering for task execution begins with the `distribute_tasks` function.
   - This function gathers compute units (e.g., processors or GPUs) and starts findings a correct order of execution for the tasks based on their dependencies.

4. **Dependency Resolution**:
   - For each task, the system resolves dependencies by:
     - Checking the task's arguments and their access pattern
     - Identifying dependencies between tasks.
     - Ensuring that all dependencies are completed before executing the current task.

5. **Aliasing Handling**:
   - For each task argument, the system:
     - Identifies aliases to determine if multiple tasks are referencing the same memory location.
     - Creates data copies when aliasing occurs to avoid memory conflicts.
     - This new copy operation is enqueued to the upper_queue as a new task so that the dependent task gets the most recent and last modified version of the data (argument) it needs to start its own execution

6. **Scheduling**:
   - A naive scheduler is used to:
     - Estimate the cost of executing each task on available processors.
     - Assign tasks to the most optimal processor.

7. **Synchronization**:
   - Before execution, tasks synchronize on their arguments based on the access pattern (`read`, `write`, or `read-write`):
     - **Read Dependencies (`read_deps`)**: Ensure no other task is modifying the argument before reading.
     - **Write Dependencies (`write_deps`)**: Ensure no other task is accessing the argument when writing.

8. **Task Execution**:
   - Once all dependencies are resolved and the task's turn is reached
   - After enqueuing all tasks (original tasks, copy tasks needed, ....) we then return execution to the wait_all func.
   - For each task enqueued we call fetch for it and its exection starts
     - The system starts the real execution of the task.
     - Tasks execute in parallel on assigned processors.
