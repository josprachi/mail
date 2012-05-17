/* Copyright 2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

private class Geary.ReplayQueue {
    private class ReplayClose : ReplayOperation {
        public ReplayClose() {
            // LOCAL_AND_REMOTE to make sure this operation is flushed all the way down the pipe
            base ("Close", ReplayOperation.Scope.LOCAL_AND_REMOTE);
        }
        
        public override async ReplayOperation.Status replay_local_async() throws Error {
            return Status.CONTINUE;
        }
        
        public override async ReplayOperation.Status replay_remote_async() throws Error {
            return Status.COMPLETED;
        }
        
        public override async void backout_local_async() throws Error {
            // nothing to backout (and should never be called, to boot)
        }
        
        public override string describe_state() {
            return "";
        }
    }
    
    public int local_count { get {
        return local_queue.size;
    } }
    
    public int remote_count { get {
        return remote_queue.size;
    } }
    
    private NonblockingMailbox<ReplayOperation> local_queue = new NonblockingMailbox<ReplayOperation>();
    private NonblockingMailbox<ReplayOperation> remote_queue = new NonblockingMailbox<ReplayOperation>();
    
    private bool is_closed = false;
    
    public virtual signal void scheduled(ReplayOperation op) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::scheduled: %s %s", op.to_string());
    }
    
    public virtual signal void locally_executing(ReplayOperation op) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::locally-executing: %s", op.to_string());
    }
    
    public virtual signal void locally_executed(ReplayOperation op, bool continuing) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::locally-executed: %s continuing=%s",
            op.to_string(), continuing.to_string());
    }
    
    public virtual signal void remotely_executing(ReplayOperation op) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::remotely-executing: %s", op.to_string());
    }
    
    public virtual signal void remotely_executed(ReplayOperation op) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::remotely-executed: %s", op.to_string());
    }
    
    public virtual signal void backing_out(ReplayOperation op, bool failed, Error? err) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::backout-out: %s failed=%s err=%s",
            op.to_string(), failed.to_string(), (err != null) ? err.message : "(null)");
    }
    
    public virtual signal void backed_out(ReplayOperation op, bool failed, Error? err) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::backed-out: %s failed=%s err=%s",
            op.to_string(), failed.to_string(), (err != null) ? err.message : "(null)");
    }
    
    public virtual signal void backout_failed(ReplayOperation op, Error? backout_err) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::backout-failed: %s err=%s", op.to_string(),
            (backout_err != null) ? backout_err.message : "(null)");
    }
    
    public virtual signal void completed(ReplayOperation op) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::completed: %s", op.to_string());
    }
    
    public virtual signal void failed(ReplayOperation op) {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::failed: %s", op.to_string());
    }
    
    public virtual signal void closing() {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::closing");
    }
    
    public virtual signal void closed() {
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue::closed");
    }
    
    public ReplayQueue() {
        // fire off background queue processors
        do_replay_local_async.begin();
        do_replay_remote_async.begin();
    }
    
    public void schedule(ReplayOperation op) {
        if (is_closed) {
            debug("Unable to scheduled replay operation %s: replay queue closed", op.to_string());
            
            return;
        }
        
        // note that in order for this to work (i.e. for sent and received operations to be handled
        // in order), it's *vital* that even REMOTE_ONLY operations go through the local queue,
        // only being scheduled on the remote queue *after* local operations ahead of it have
        // completed; thus, no need for get_scope() to be called here.
        try {
            local_queue.send(op);
        } catch (Error err) {
            debug("Replay operation %s not scheduled on local queue: %s", op.to_string(), err.message);
        }
        
        scheduled(op);
    }
    
    public async void close_async(Cancellable? cancellable = null) throws Error {
        if (is_closed)
            return;
        
        is_closed = true;
        
        closing();
        
        // flush a ReplayClose operation down the pipe so all enqueued operations complete
        ReplayClose close_op = new ReplayClose();
        schedule(close_op);
        
        yield close_op.wait_for_ready_async(cancellable);
        
        closed();
    }
    
    private async void do_replay_local_async() {
        for (;;) {
            if (local_queue.size == 0 && is_closed)
                break;
            
            ReplayOperation op;
            try {
                op = yield local_queue.recv_async();
            } catch (Error recv_err) {
                debug("Unable to receive next replay operation on local queue: %s", recv_err.message);
                
                continue;
            }
            
            bool local_execute = false;
            bool remote_enqueue = false;
            switch (op.scope) {
                case ReplayOperation.Scope.LOCAL_AND_REMOTE:
                    local_execute = true;
                    remote_enqueue = true;
                break;
                
                case ReplayOperation.Scope.LOCAL_ONLY:
                    local_execute = true;
                    remote_enqueue = false;
                break;
                
                case ReplayOperation.Scope.REMOTE_ONLY:
                    local_execute = false;
                    remote_enqueue = true;
                break;
                
                default:
                    assert_not_reached();
            }
            
            if (local_execute) {
                locally_executing(op);
                
                try {
                    switch (yield op.replay_local_async()) {
                        case ReplayOperation.Status.COMPLETED:
                            // done
                            remote_enqueue = false;
                            op.notify_ready(false, null);
                        break;
                        
                        case ReplayOperation.Status.CONTINUE:
                            // don't touch remote_enqueue; if already false, CONTINUE is treated as
                            // COMPLETED.
                            if (!remote_enqueue)
                                op.notify_ready(false, null);
                        break;
                        
                        case ReplayOperation.Status.FAILED:
                            // done
                            remote_enqueue = false;
                            op.notify_ready(true, null);
                        break;
                        
                        default:
                            assert_not_reached();
                    }
                } catch (Error replay_err) {
                    debug("Replay local error for %s: %s", op.to_string(), replay_err.message);
                    
                    op.notify_ready(false, replay_err);
                    remote_enqueue = false;
                }
            }
            
            if (remote_enqueue) {
                try {
                    remote_queue.send(op);
                } catch (Error send_err) {
                    error("ReplayOperation %s not scheduled on remote queue: %s", op.to_string(),
                        send_err.message);
                }
            } else {
                // all code paths to this point should have notified ready if not enqueuing for
                // next stage
                assert(op.notified);
            }
            
            if (local_execute)
                locally_executed(op, remote_enqueue);
            
            if (!remote_enqueue) {
                if (!op.failed && op.err == null)
                    completed(op);
                else
                    failed(op);
            }
        }
        
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue.do_replay_local_async exiting");
    }
    
    private async void do_replay_remote_async() {
        for (;;) {
            if (remote_queue.size == 0 && is_closed)
                break;
            
            ReplayOperation op;
            try {
                op = yield remote_queue.recv_async();
            } catch (Error recv_err) {
                debug("Unable to receive next replay operation on remote queue: %s", recv_err.message);
                
                continue;
            }
            
            remotely_executing(op);
            
            ReplayOperation.Status status = ReplayOperation.Status.FAILED;
            Error? remote_err = null;
            try {
                status = yield op.replay_remote_async();
            } catch (Error replay_err) {
                debug("Replay remote error for %s: %s", op.to_string(), replay_err.message);
                
                remote_err = replay_err;
            }
            
            bool has_failed = (status == ReplayOperation.Status.FAILED);
            
            // COMPLETED == CONTINUE, only FAILED or exception of interest here
            if (remote_err != null || has_failed) {
                try {
                    backing_out(op, has_failed, remote_err);
                    
                    yield op.backout_local_async();
                    
                    backed_out(op, has_failed, remote_err);
                } catch (Error backout_err) {
                    backout_failed(op, backout_err);
                }
            }
            
            // use the remote error (not the backout error) for the operation's completion
            // state
            op.notify_ready(has_failed, remote_err);
            
            remotely_executed(op);
            
            if (!op.failed && op.err == null)
                completed(op);
            else
                failed(op);
        }
        
        Logging.debug(Logging.Flag.REPLAY, "ReplayQueue.do_replay_remote_async exiting");
    }
}

